/**
 * Translate command-line parameters to a function signature,
 * generating --help text automatically.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.funopt;

import std.algorithm;
import std.array;
import std.conv;
import std.getopt;
import std.path;
import std.range;
import std.string;
import std.traits;
import std.typetuple;

import ae.utils.meta : structFields, hasAttribute, getAttribute, RangeTuple, I;
import ae.utils.array : split1;
import ae.utils.text;

private enum OptionType { switch_, option, parameter }

struct OptionImpl(OptionType type_, T_, string description_, char shorthand_, string placeholder_, string name_)
{
	enum type = type_;
	alias T = T_;
	enum description = description_;
	enum shorthand = shorthand_;
	enum placeholder = placeholder_;
	enum name = name_;

	T value;
	alias value this;

	this(T value_)
	{
		value = value_;
	}
}

/// An on/off switch (e.g. --verbose). Does not have a value, other than its presence.
template Switch(string description=null, char shorthand=0, string name=null)
{
	alias Switch = OptionImpl!(OptionType.switch_, bool, description, shorthand, null, name);
}

/// An option with a value (e.g. --tries N). The default placeholder depends on the type
/// (N for numbers, STR for strings).
template Option(T, string description=null, string placeholder=null, char shorthand=0, string name=null)
{
	alias Option = OptionImpl!(OptionType.option, T, description, shorthand, placeholder, name);
}

/// An ordered parameter.
template Parameter(T, string description=null, string name=null)
{
	alias Parameter = OptionImpl!(OptionType.parameter, T, description, 0, null, name);
}

/// Specify this as the description to hide the option from --help output.
enum hiddenOption = "hiddenOption";

private template OptionValueType(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		alias OptionValueType = T.T;
	else
		alias OptionValueType = T;
}

private OptionValueType!T* optionValue(T)(ref T option)
{
	static if (is(T == OptionImpl!Args, Args...))
		return &option.value;
	else
		return &option;
}

private template isParameter(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum isParameter = T.type == OptionType.parameter;
	else
	static if (is(T == bool))
		enum isParameter = false;
	else
		enum isParameter = true;
}

private template isOptionArray(Param)
{
	alias T = OptionValueType!Param;
	static if (is(Unqual!T == string))
		enum isOptionArray = false;
	else
	static if (is(T U : U[]))
		enum isOptionArray = true;
	else
		enum isOptionArray = false;
}

private template optionShorthand(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum optionShorthand = T.shorthand;
	else
		enum char optionShorthand = 0;
}

private template optionDescription(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum optionDescription = T.description;
	else
		enum string optionDescription = null;
}

private enum bool optionHasDescription(T) = !isHiddenOption!T && optionDescription!T !is null;

private template optionPlaceholder(T)
{
	static if (is(T == OptionImpl!Args, Args...))
	{
		static if (T.placeholder.length)
			enum optionPlaceholder = T.placeholder;
		else
			enum optionPlaceholder = optionPlaceholder!(OptionValueType!T);
	}
	else
	static if (isOptionArray!T)
		enum optionPlaceholder = optionPlaceholder!(typeof(T.init[0]));
	else
	static if (is(T : real))
		enum optionPlaceholder = "N";
	else
	static if (is(T == string))
		enum optionPlaceholder = "STR";
	else
		enum optionPlaceholder = "X";
}

private template optionName(T, string paramName)
{
	static if (is(T == OptionImpl!Args, Args...))
		static if (T.name)
			enum optionName = T.name;
		else
			enum optionName = paramName;
	else
		enum optionName = paramName;
}

private template isHiddenOption(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		static if (T.description is hiddenOption)
			enum isHiddenOption = true;
		else
			enum isHiddenOption = false;
	else
		enum isHiddenOption = false;
}

struct FunOptConfig
{
	std.getopt.config[] getoptConfig;
}

private template optionNames(alias FUN)
{
	alias Params = ParameterTypeTuple!FUN;
	alias parameterNames = ParameterIdentifierTuple!FUN;
	enum optionNameAt(int i) = optionName!(Params[i], parameterNames[i]);
	alias optionNames = staticMap!(optionNameAt, RangeTuple!(parameterNames.length));
}

/// Default help text print function.
/// Sends the text to stderr.writeln.
void defaultUsageFun(string usage)
{
	import std.stdio;
	stderr.writeln(usage);
}

/// Parse the given arguments according to FUN's parameters, and call FUN.
/// Throws GetOptException on errors.
auto funopt(alias FUN, FunOptConfig config = FunOptConfig.init, alias usageFun = defaultUsageFun)(string[] args)
if (isFunction!FUN)
{
	alias Params = staticMap!(Unqual, ParameterTypeTuple!FUN);
	Params values;
	enum names = optionNames!FUN;
	alias defaults = ParameterDefaultValueTuple!FUN;

	foreach (i, defaultValue; defaults)
	{
		static if (!is(defaultValue == void))
		{
			//values[i] = defaultValue;
			// https://issues.dlang.org/show_bug.cgi?id=13252
			values[i] = cast(OptionValueType!(Params[i])) defaultValue;
		}
	}

	enum structFields =
		config.getoptConfig.length.iota.map!(n => "std.getopt.config config%d = std.getopt.config.%s;\n".format(n, config.getoptConfig[n])).join() ~
		Params.length.iota.map!(n => "string selector%d; OptionValueType!(Params[%d])* value%d;\n".format(n, n, n)).join();

	static struct GetOptArgs { mixin(structFields); }
	GetOptArgs getOptArgs;

	static string optionSelector(int i)()
	{
		string[] variants;
		auto shorthand = optionShorthand!(Params[i]);
		if (shorthand)
			variants ~= [shorthand];
		enum keywords = names[i].identifierToCommandLineKeywords();
		variants ~= keywords;
		return variants.join("|");
	}

	foreach (i, ref value; values)
	{
		enum selector = optionSelector!i();
		mixin("getOptArgs.selector%d = selector;".format(i));
		mixin("getOptArgs.value%d = optionValue(values[%d]);".format(i, i));
	}

	auto origArgs = args;
	bool help;

	getopt(args,
		std.getopt.config.bundling,
		getOptArgs.tupleof,
		"h|help", &help,
	);

	void printUsage()
	{
		usageFun(getUsage!FUN(origArgs[0]));
	}

	if (help)
	{
		printUsage();
		static if (is(ReturnType!FUN == void))
			return;
		else
			return ReturnType!FUN.init;
	}

	args = args[1..$];

	// Slurp remaining, unparsed arguments into parameter fields

	foreach (i, ref value; values)
	{
		alias T = Params[i];
		static if (isParameter!T)
		{
			static if (is(OptionValueType!T : const(string)[]))
			{
				values[i] = cast(OptionValueType!T)args;
				args = null;
			}
			else
			{
				if (args.length)
				{
					values[i] = to!(OptionValueType!T)(args[0]);
					args = args[1..$];
				}
				else
				{
					static if (is(defaults[i] == void))
					{
						// If the first argument is mandatory,
						// and no arguments were given, print usage.
						if (origArgs.length == 1)
							printUsage();

						enum plainName = names[i].identifierToPlainText;
						throw new GetOptException("No " ~ plainName ~ " specified.");
					}
				}
			}
		}
	}

	if (args.length)
		throw new GetOptException("Extra parameters specified: %(%s %)".format(args));

	return FUN(values);
}

unittest
{
	void f1(bool verbose, Option!int tries, string filename)
	{
		assert(verbose);
		assert(tries == 5);
		assert(filename == "filename.ext");
	}
	funopt!f1(["program", "--verbose", "--tries", "5", "filename.ext"]);

	void f2(string a, Parameter!string b, string[] rest)
	{
		assert(a == "a");
		assert(b == "b");
		assert(rest == ["c", "d"]);
	}
	funopt!f2(["program", "a", "b", "c", "d"]);

	void f3(Option!(string[], null, "DIR", 'x') excludeDir)
	{
		assert(excludeDir == ["a", "b", "c"]);
	}
	funopt!f3(["program", "--excludedir", "a", "--exclude-dir", "b", "-x", "c"]);

	void f4(Option!string outputFile = "output.txt", string inputFile = "input.txt", string[] dataFiles = null)
	{
		assert(inputFile == "input.txt");
		assert(outputFile == "output.txt");
		assert(dataFiles == []);
	}
	funopt!f4(["program"]);

	void f5(string input = null)
	{
		assert(input is null);
	}
	funopt!f5(["program"]);
}

// ***************************************************************************

private string canonicalizeCommandLineArgument(string s) { return s.replace("-", ""); }
private string canonicalizeIdentifier(string s) { return s.chomp("_").toLower(); }
private string identifierToCommandLineKeyword(string s) { return s.chomp("_").splitByCamelCase.join("-").toLower(); }
private string identifierToCommandLineParam  (string s) { return s.chomp("_").splitByCamelCase.join("-").toUpper(); }
private string identifierToPlainText         (string s) { return s.chomp("_").splitByCamelCase.join(" ").toLower(); }
private string[] identifierToCommandLineKeywords(string s) { auto words = s.chomp("_").splitByCamelCase(); return [words.join().toLower()] ~ (words.length > 1 ? [words.join("-").toLower()] : []); } /// for getopt

private string getProgramName(string program)
{
	auto programName = program.baseName();
	version(Windows)
	{
		programName = programName.toLower();
		if (programName.extension == ".exe")
			programName = programName.stripExtension();
	}

	return programName;
}

private string escapeFmt(string s) { return s.replace("%", "%%"); }

string getUsage(alias FUN)(string program)
{
	auto programName = getProgramName(program);
	enum formatString = getUsageFormatString!FUN();
	return formatString.format(programName);
}

string getUsageFormatString(alias FUN)()
{
	alias ParameterTypeTuple!FUN Params;
	enum names = [optionNames!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	string result = "Usage: %s";
	enum inSynopsis(Param) = isParameter!Param || !optionHasDescription!Param;
	enum haveOmittedOptions = !allSatisfy!(inSynopsis, Params);
	static if (haveOmittedOptions)
		result ~= " [OPTION]...";

	string getSwitchText(int i)()
	{
		alias Param = Params[i];
		static if (isParameter!Param)
			return names[i].identifierToCommandLineParam();
		else
		{
			string switchText = "--" ~ names[i].identifierToCommandLineKeyword();
			static if (is(Param == OptionImpl!Args, Args...))
				static if (Param.type == OptionType.option)
					switchText ~= (optionPlaceholder!Param.canFind('=') ? ' ' : '=') ~ optionPlaceholder!Param;
			return switchText;
		}
	}

	string optionalEnd;
	void flushOptional() { result ~= optionalEnd; optionalEnd = null; }
	foreach (i, Param; Params)
		static if (!isHiddenOption!Param && inSynopsis!Param)
		{
			static if (isParameter!Param)
			{
				result ~= " ";
				static if (!is(defaults[i] == void))
				{
					result ~= "[";
					optionalEnd ~= "]";
				}
				result ~= names[i].identifierToCommandLineParam();
			}
			else
			{
				flushOptional();
				result ~= " [" ~ getSwitchText!i().escapeFmt() ~ "]";
			}
			static if (isOptionArray!Param)
				result ~= "...";
		}
	flushOptional();

	result ~= "\n";

	enum haveDescriptions = anySatisfy!(optionHasDescription, Params);
	static if (haveDescriptions)
	{
		enum haveShorthands = anySatisfy!(optionShorthand, Params);
		string[Params.length] selectors;
		size_t longestSelector;

		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
			{
				string switchText = getSwitchText!i();
				if (haveShorthands)
				{
					auto c = optionShorthand!Param;
					if (c)
						selectors[i] = "-%s, %s".format(c, switchText);
					else
						selectors[i] = "    %s".format(switchText);
				}
				else
					selectors[i] = switchText;
				longestSelector = max(longestSelector, selectors[i].length);
			}

		result ~= "\nOptions:\n";
		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
				result ~= optionWrap(optionDescription!Param.escapeFmt(), selectors[i], longestSelector);
	}

	return result;
}

string optionWrap(string text, string firstIndent, size_t indentWidth)
{
	enum width = 79;
	auto padding = " ".replicate(2 + indentWidth + 2);
	text = text.findSplit("\n\n")[0];
	auto paragraphs = text.split1("\n");
	auto result = verbatimWrap(
		paragraphs[0],
		width,
		"  %-*s  ".format(indentWidth, firstIndent),
		padding
	);
	result ~= paragraphs[1..$].map!(p => verbatimWrap(p, width, padding, padding)).join();
	return result;
}

unittest
{
	void f1(
		Switch!("Enable verbose logging", 'v') verbose,
		Option!(int, "Number of tries") tries,
		Option!(int, "Seconds to\nwait each try", "SECS", 0, "timeout") t,
		in string filename,
		string output = "default",
		string[] extraFiles = null
	)
	{}

	auto usage = getUsage!f1("program");
	assert(usage ==
"Usage: program [OPTION]... FILENAME [OUTPUT [EXTRA-FILES...]]

Options:
  -v, --verbose       Enable verbose logging
      --tries=N       Number of tries
      --timeout=SECS  Seconds to
                      wait each try
", usage);

	void f2(
		bool verbose,
		Option!(string[]) extraFile,
		string filename,
		string output = "default",
	)
	{}

	usage = getUsage!f2("program");
	assert(usage ==
"Usage: program [--verbose] [--extra-file=STR]... FILENAME [OUTPUT]
", usage);

	void f3(
		Parameter!(string[]) args = null,
	)
	{}

	usage = getUsage!f3("program");
	assert(usage ==
"Usage: program [ARGS...]
", usage);

	void f4(
		Parameter!(string[], "The program arguments.") args = null,
	)
	{}

	usage = getUsage!f4("program");
	assert(usage ==
"Usage: program [ARGS...]

Options:
  ARGS  The program arguments.
", usage);

	void f5(
		Option!(string[], "Features to disable.") without = null,
	)
	{}

	usage = getUsage!f5("program");
	assert(usage ==
"Usage: program [OPTION]...

Options:
  --without=STR  Features to disable.
", usage);

	// If all options are on the command line, don't add "[OPTION]..."
	void f6(
		bool verbose,
		Parameter!(string[], "Files to transmogrify.") files = null,
	)
	{}

	usage = getUsage!f6("program");
	assert(usage ==
"Usage: program [--verbose] [FILES...]

Options:
  FILES  Files to transmogrify.
", usage);

	// Ensure % characters work as expected.
	void f7(
		Parameter!(int, "How much power % to use.") powerPct,
	)
	{}

	usage = getUsage!f7("program");
	assert(usage ==
"Usage: program POWER-PCT

Options:
  POWER-PCT  How much power % to use.
", usage);
}

// ***************************************************************************

/// Dispatch the command line to a type's static methods, according to the
/// first parameter on the given command line (the "action").
/// String UDAs are used as usage documentation for generating --help output
/// (or when no action is specified).
auto funoptDispatch(alias Actions, FunOptConfig config = FunOptConfig.init, alias usageFun = defaultUsageFun)(string[] args)
{
	string program = args[0];

	auto fun(string action, string[] actionArguments = [])
	{
		action = action.canonicalizeCommandLineArgument();

		static void descUsageFun(string description)(string usage)
		{
			auto lines = usage.split("\n");
			usageFun((lines[0..1] ~ [null, description] ~ lines[1..$]).join("\n"));
		}

		foreach (m; __traits(allMembers, Actions))
			static if (is(typeof(hasAttribute!(string, __traits(getMember, Actions, m)))))
			{
				alias member = I!(__traits(getMember, Actions, m));
				enum name = m.canonicalizeIdentifier();
				if (name == action)
				{
					static if (hasAttribute!(string, member))
					{
						enum description = getAttribute!(string, member);
						alias myUsageFun = descUsageFun!description;
					}
					else
						alias myUsageFun = usageFun;

					auto args = [getProgramName(program) ~ " " ~ action] ~ actionArguments;
					static if (is(member == struct))
						return funoptDispatch!(member, config, usageFun)(args);
					else
						return funopt!(member, config, myUsageFun)(args);
				}
			}

		throw new GetOptException("Unknown action: " ~ action);
	}

	static void myUsageFun(string usage) { usageFun(usage ~ funoptDispatchUsage!Actions()); }

	const FunOptConfig myConfig = (){
		auto c = config;
		c.getoptConfig ~= std.getopt.config.stopOnFirstNonOption;
		return c;
	}();
	return funopt!(fun, myConfig, myUsageFun)(args);
}

string funoptDispatchUsage(alias Actions)()
{
	string result = "\nActions:\n";

	size_t longestAction = 0;
	foreach (m; __traits(allMembers, Actions))
		static if (is(typeof(hasAttribute!(string, __traits(getMember, Actions, m)))))
			static if (hasAttribute!(string, __traits(getMember, Actions, m)))
			{
				enum length = m.identifierToCommandLineKeyword().length;
				longestAction = max(longestAction, length);
			}

	foreach (m; __traits(allMembers, Actions))
		static if (is(typeof(hasAttribute!(string, __traits(getMember, Actions, m)))))
			static if (hasAttribute!(string, __traits(getMember, Actions, m)))
			{
				enum name = m.identifierToCommandLineKeyword();
				//__traits(comment, __traits(getMember, Actions, m)) // https://github.com/D-Programming-Language/dmd/pull/3531
				result ~= optionWrap(getAttribute!(string, __traits(getMember, Actions, m)), name, longestAction);
			}

	return result;
}

unittest
{
	struct Actions
	{
		@(`Perform action f1`)
		static void f1(bool verbose) {}

		@(`Perform complicated action f2

This action is complicated because of reasons.`)
		static void f2() {}

		@(`An action sub-group`)
		struct fooBar
		{
			@(`Create a new foobar`)
			static void new_() {}
		}
	}

	funoptDispatch!Actions(["program", "f1", "--verbose"]);

	assert(funoptDispatchUsage!Actions() == "
Actions:
  f1       Perform action f1
  f2       Perform complicated action f2
  foo-bar  An action sub-group
");

	funoptDispatch!Actions(["program", "foo-bar", "new"]);

	assert(funoptDispatchUsage!(Actions.fooBar)() == "
Actions:
  new  Create a new foobar
");

	static string usage;
	static void usageFun(string _usage) { usage = _usage; }
	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "f1", "--help"]);
	assert(usage == "Usage: unittest f1 [--verbose]

Perform action f1
", usage);

	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "f2", "--help"]);
	assert(usage == "Usage: unittest f2

Perform complicated action f2

This action is complicated because of reasons.
", usage);
}
