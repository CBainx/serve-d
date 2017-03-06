import core.thread;

import io = std.stdio;
import fs = std.file;
import std.getopt;
import std.functional;
import std.algorithm;
import std.string;
import std.json;
import std.path;
import std.conv;
import std.traits;

import served.fibermanager;
import served.filereader;
import served.jsonrpc;
import served.types;

static import served.extension;

import painlessjson;

bool initialized = false;

alias Identity(I...) = I;

ResponseMessage processRequest(RequestMessage msg)
{
	ResponseMessage res;
	res.id = msg.id;
	if (msg.method == "initialize" && !initialized)
	{
		res.result = served.extension.initialize(msg.params.fromJSON!InitializeParams).toJSON;
		initialized = true;
		return res;
	}
	if (!initialized)
	{
		res.error = ResponseError(ErrorCode.serverNotInitialized);
		return res;
	}
	foreach (name; __traits(derivedMembers, served.extension))
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
			{
				static if (hasUDA!(symbol, protocolMethod))
				{
					enum method = getUDAs!(symbol, protocolMethod)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							static if (params.length == 0)
								res.result = symbol[0]().toJSON;
							else static if (params.length == 1)
								res.result = symbol[0](fromJSON!(Parameters!symbol[0])(msg.params)).toJSON;
							else
								static assert(0, "Can't have more than one argument");
							return res;
						}
						catch (MethodException e)
						{
							res.error = e.error;
							return res;
						}
					}
				}
			}
		}
	}

	io.stderr.writeln(msg);
	res.error = ResponseError(ErrorCode.methodNotFound);
	return res;
}

void processNotify(RequestMessage msg)
{
	if (msg.method == "exit")
	{
		rpc.stop();
		return;
	}
	if (msg.method == "workspace/didChangeConfiguration")
	{
		auto newConfig = msg.params["settings"].fromJSON!Configuration;
		served.extension.changedConfig(served.types.config.replace(newConfig));
	}
	documents.process(msg);
	foreach (name; __traits(derivedMembers, served.extension))
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
			{
				static if (hasUDA!(symbol, protocolNotification))
				{
					enum method = getUDAs!(symbol, protocolNotification)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							static if (params.length == 0)
								symbol[0]();
							else static if (params.length == 1)
								symbol[0](fromJSON!(Parameters!symbol[0])(msg.params));
							else
								static assert(0, "Can't have more than one argument");
						}
						catch (MethodException e)
						{
							io.stderr.writeln(e);
						}
					}
				}
			}
		}
	}
}

void printVersion()
{
	import workspaced.info : WorkspacedVersion = Version;
	import source.served.info;

	io.writefln("serve-d v%(%s.%) with workspace-d v%(%s.%)", Version, WorkspacedVersion);
	io.writefln("Included features: %(%s, %)", IncludedFeatures);
}

void main(string[] args)
{
	bool printVer;
	string[] features;
	auto argInfo = args.getopt("r|require",
			"Adds a feature set that is required. Unknown feature sets will intentionally crash on startup",
			&features, "v|version", "Print version of program", &printVer);
	if (argInfo.helpWanted)
	{
		if (printVer)
			printVersion();
		defaultGetoptPrinter("workspace-d / vscode-language-server bridge", argInfo.options);
		return;
	}
	if (printVer)
	{
		printVersion();
		return;
	}
	served.types.workspaceRoot = fs.getcwd();
	foreach (feature; features)
		if (!IncludedFeatures.canFind(feature.toLower.strip))
			throw new Exception("Feature set '" ~ feature ~ "' not in this version of serve-d");
	auto input = new FileReader(io.stdin);
	input.start();
	rpc = new RPCProcessor(input, io.stdout);
	rpc.call();
	FiberManager fibers;
	fibers ~= rpc;
	while (rpc.state != Fiber.State.TERM)
	{
		while (rpc.hasData)
		{
			auto msg = rpc.poll;
			if (msg.id.hasData)
				fibers ~= new Fiber({
					ResponseMessage res;
					try
					{
						res = processRequest(msg);
					}
					catch (Exception e)
					{
						res.error = ResponseError(e);
						res.error.code = ErrorCode.internalError;
					}
					rpc.send(res);
				}, 4096 * 16);
			else
				fibers ~= new Fiber({
					try
					{
						processNotify(msg);
					}
					catch (Exception e)
					{
						io.stderr.writeln(e);
					}
				}, 4096 * 16);
		}
		Thread.sleep(10.msecs);
		fibers.call();
	}
}