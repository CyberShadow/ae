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
 *   Vladimir Panteleev <ae@cy.md>
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
import std.typecons : Nullable, nullable;
import std.typetuple;

import ae.utils.meta : structFields, hasAttribute, getAttribute, rangeTuple, I, ParameterNames;
import ae.utils.array : split1;
import ae.utils.text;

public static import std.getopt; // See ae.utils.main

private enum OptionType { switch_, option, parameter }

struct _OptionImpl(OptionType type_, T_, string description_, char shorthand_, string placeholder_, string name_)
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
	alias Switch = _OptionImpl!(OptionType.switch_, bool, description, shorthand, null, name);
}

/// An option with a value (e.g. --tries N). The default placeholder depends on the type
/// (N for numbers, STR for strings).
template Option(T, string description=null, string placeholder=null, char shorthand=0, string name=null)
{
	alias Option = _OptionImpl!(OptionType.option, T, description, shorthand, placeholder, name);
}

/// A positional parameter.
template Parameter(T, string description=null, string name=null)
{
	alias Parameter = _OptionImpl!(OptionType.parameter, T, description, 0, null, name);
}

/// Specify this as the description to hide the option from --help output.
enum hiddenOption = "hiddenOption";

/// UDA for specifying program version.
/// Enables a `--version` option.
/// Specify this as the full version string to be displayed,
/// e.g. `@Version("myapp v1.2.3")`.
struct Version
{
	string value;
}

/// Extracts version string from a symbol's `Version` UDA, or returns `null` if absent.
template getVersionString(alias sym)
{
	static if (hasAttribute!(Version, sym))
		enum getVersionString = getAttribute!(Version, sym).value;
	else
		enum string getVersionString = null;
}

private template OptionValueType(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
		alias OptionValueType = T.T;
	else
		alias OptionValueType = T;
}

private OptionValueType!T* optionValue(T)(ref T option)
{
	static if (is(T == _OptionImpl!Args, Args...))
		return &option.value;
	else
		return &option;
}

private template isParameter(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
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
	static if (isInstanceOf!(Nullable, T))
		enum isOptionArray = false;
	else
	static if (is(Unqual!T == string))
		enum isOptionArray = false;
	else
	static if (is(T U : U[]))
		enum isOptionArray = true;
	else
		enum isOptionArray = false;
}

private template isNullable(T)
{
	static if (is(T : Nullable!U, U))
		enum isNullable = true;
	else
		enum isNullable = false;
}

/// For Nullable!T, returns T. Otherwise, returns the type unchanged.
private template NullableTarget(T)
{
	static if (is(T : Nullable!U, U))
		alias NullableTarget = U;
	else
		alias NullableTarget = T;
}

/// Returns the type that getopt should parse for a given option type.
/// For Nullable types, this is the inner type.
private template GetoptValueType(Param)
{
	alias T = OptionValueType!Param;
	alias GetoptValueType = NullableTarget!T;
}

private template isNullableOption(Param)
{
	enum isNullableOption = isNullable!(OptionValueType!Param);
}

private template optionShorthand(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
		enum optionShorthand = T.shorthand;
	else
		enum char optionShorthand = 0;
}

private template optionDescription(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
		enum optionDescription = T.description;
	else
		enum string optionDescription = null;
}

private enum bool optionHasDescription(T) = !isHiddenOption!T && optionDescription!T !is null;

private template optionPlaceholder(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
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
	static if (isNullable!T)
		enum optionPlaceholder = optionPlaceholder!(NullableTarget!T);
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
	static if (is(T == _OptionImpl!Args, Args...))
		static if (T.name)
			enum optionName = T.name;
		else
			enum optionName = paramName;
	else
		enum optionName = paramName;
}

private template isHiddenOption(T)
{
	static if (is(T == _OptionImpl!Args, Args...))
		static if (T.description is hiddenOption)
			enum isHiddenOption = true;
		else
			enum isHiddenOption = false;
	else
		enum isHiddenOption = false;
}

/// `funopt` configuration.
struct FunOptConfig
{
	/// `getopt` configuration.
	std.getopt.config[] getoptConfig;
}

private template optionNames(alias FUN)
{
	alias Params = ParameterTypeTuple!FUN;
	alias parameterNames = ParameterNames!FUN;
	enum optionNameAt(int i) = optionName!(Params[i], parameterNames[i]);
	alias optionNames = staticMap!(optionNameAt, rangeTuple!(parameterNames.length));
}

/// Default help text print function.
/// Sends the text to stderr.writeln.
void defaultUsageFun(string usage)
{
	import std.stdio;
	stderr.writeln(usage);
}

/// Default version text print function.
/// Sends the text to stdout.writeln.
void defaultVersionFun(string ver)
{
	import std.stdio;
	stdout.writeln(ver);
}

/// Parse the given arguments according to FUN's parameters, and call FUN.
/// Throws GetOptException on errors.
auto funopt(alias FUN, FunOptConfig config = FunOptConfig.init, alias usageFun = defaultUsageFun, alias versionFun = defaultVersionFun)(string[] args)
if (isCallable!FUN)
{
	alias Params = staticMap!(Unqual, ParameterTypeTuple!FUN);
	Params values;
	enum names = optionNames!FUN;
	static immutable bool[] isIndexParameter = [staticMap!(isParameter, Params)];
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

	// Can't pass options with empty names to getopt, filter them out.
	static immutable string[] namesArr = [names];
	static immutable bool[] optionUseGetOpt = Params.length.iota.map!(n => namesArr[n].length > 0 && !isIndexParameter[n]).array;
	static immutable bool[] isNullableArr = [staticMap!(isNullableOption, Params)];

	// For Nullable types, we use a delegate handler instead of a pointer,
	// so that we can detect whether the option was specified.
	// std.getopt accepts void delegate(string, string) for custom parsing.
	enum structFields =
		config.getoptConfig.length.iota.map!(n => "std.getopt.config config%d = std.getopt.config.%s;\n".format(n, config.getoptConfig[n])).join() ~
		Params.length.iota
			.filter!(n => optionUseGetOpt[n])
			.map!(n => isNullableArr[n]
				? "string selector%d; void delegate(string, string) handler%d;\n".format(n, n)
				: "string selector%d; OptionValueType!(Params[%d])* value%d;\n".format(n, n, n)).join();

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
		static if (optionUseGetOpt[i])
		{
			enum selector = optionSelector!i();
			mixin("getOptArgs.selector%d = selector;".format(i));
			static if (isNullableOption!(Params[i]))
				mixin("getOptArgs.handler%d = (string, string val) { *optionValue(values[%d]) = nullable(val.to!(GetoptValueType!(Params[%d]))); };".format(i, i, i));
			else
				mixin("getOptArgs.value%d = optionValue(values[%d]);".format(i, i));
		}

	auto origArgs = args;
	bool help;
	enum ver = getVersionString!FUN;
	enum haveVersion = ver.length > 0;
	static if (haveVersion)
		bool showVersion;

	struct FlagOpt { string selector; bool* value; }
	struct NoOpt {}
	Select!(haveVersion, FlagOpt, NoOpt) versionOpt;
	static if (haveVersion)
		versionOpt = FlagOpt("V|version", &showVersion);

	getopt(args,
		std.getopt.config.bundling,
		std.getopt.config.caseSensitive,
		getOptArgs.tupleof,
		"h|help", &help,
		versionOpt.tupleof,
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

	static if (haveVersion)
	{
		if (showVersion)
		{
			versionFun(ver);
			static if (is(ReturnType!FUN == void))
				return;
			else
				return ReturnType!FUN.init;
		}
	}

	args = args[1..$];

	// Slurp remaining, unparsed arguments into parameter fields

	foreach (i, ref value; values)
	{
		alias T = Params[i];
		static if (isParameter!T)
		{
			static if (isOptionArray!(OptionValueType!T))
			{
				values[i] = args.map!(arg => arg.to!(ElementType!(OptionValueType!T))).array;
				args = null;
			}
			else
			{
				if (args.length)
				{
					// For Nullable types, convert to the inner type then wrap
					static if (isNullable!(OptionValueType!T))
						*optionValue(values[i]) = nullable(to!(GetoptValueType!T)(args[0]));
					else
						values[i] = to!(OptionValueType!T)(args[0]);
					args = args[1..$];
				}
				else
				{
					static if (is(defaults[i] == void))
					{
						// Nullable types without a default don't require an argument
						static if (!isNullable!(OptionValueType!T))
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
	}

	if (args.length)
		throw new GetOptException("Extra parameters specified: %(%s %)".format(args));

	return FUN(values);
}

debug(ae_unittest) unittest
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

	funopt!({})(["program"]);

	funopt!((int) {})(["program", "5"]);

	funopt!((int n) { assert(n); })(["program", "5"]);

	funopt!((int[] n) { assert(n == [12, 34]); })(["program", "12", "34"]);
}

debug(ae_unittest) unittest
{
	// Test --version support
	static string versionOutput;
	static void testVersionFun(string ver) { versionOutput = ver; }

	@Version("myapp 1.2.3")
	void f1() { assert(false, "should not be called"); }

	versionOutput = null;
	funopt!(f1, FunOptConfig.init, defaultUsageFun, testVersionFun)(["program", "--version"]);
	assert(versionOutput == "myapp 1.2.3", versionOutput);

	versionOutput = null;
	funopt!(f1, FunOptConfig.init, defaultUsageFun, testVersionFun)(["program", "-V"]);
	assert(versionOutput == "myapp 1.2.3", versionOutput);

	// Without @Version, --version should not be recognized
	void f2() {}

	import std.exception : assertThrown;
	assertThrown!GetOptException(funopt!f2(["program", "--version"]));
}

debug(ae_unittest) unittest
{
	// Test Nullable support for detecting unspecified options

	// Nullable!int option - not specified
	void f1(Option!(Nullable!int, "Number of retries") retries)
	{
		assert(retries.value.isNull);
	}
	funopt!f1(["program"]);

	// Nullable!int option - specified
	void f2(Option!(Nullable!int, "Number of retries") retries)
	{
		assert(!retries.value.isNull);
		assert(retries.value.get == 5);
	}
	funopt!f2(["program", "--retries", "5"]);

	// Nullable!string option - not specified
	void f3(Option!(Nullable!string, "Output format") format)
	{
		assert(format.value.isNull);
	}
	funopt!f3(["program"]);

	// Nullable!string option - specified
	void f4(Option!(Nullable!string, "Output format") format)
	{
		assert(!format.value.isNull);
		assert(format.value.get == "json");
	}
	funopt!f4(["program", "--format", "json"]);

	// Mix of Nullable and non-Nullable options
	void f5(
		Option!(Nullable!int, "Nullable option") nullableOpt,
		Switch!"Verbose mode" verbose,
		Option!(int, "Regular option") regularOpt = 10,
	)
	{
		assert(nullableOpt.value.isNull);
		assert(regularOpt == 10);
		assert(!verbose);
	}
	funopt!f5(["program"]);

	// Mix with some options specified
	void f6(
		Option!(Nullable!int, "Nullable option") nullableOpt,
		Switch!"Verbose mode" verbose,
		Option!(int, "Regular option") regularOpt = 10,
	)
	{
		assert(!nullableOpt.value.isNull);
		assert(nullableOpt.value.get == 42);
		assert(regularOpt == 10);
		assert(verbose);
	}
	funopt!f6(["program", "--nullable-opt", "42", "--verbose"]);

	// Bare Nullable as positional parameter (without Option wrapper)
	void f7(Nullable!int count)
	{
		assert(count.isNull);
	}
	funopt!f7(["program"]);

	void f8(Nullable!int count)
	{
		assert(!count.isNull);
		assert(count.get == 3);
	}
	funopt!f8(["program", "3"]);  // Positional, not --count

	// Parameter!(Nullable!T) - explicit positional parameter wrapper
	void f9(Parameter!(Nullable!int, "Count value") count)
	{
		assert(count.value.isNull);
	}
	funopt!f9(["program"]);

	void f10(Parameter!(Nullable!int, "Count value") count)
	{
		assert(!count.value.isNull);
		assert(count.value.get == 42);
	}
	funopt!f10(["program", "42"]);
}

// ***************************************************************************

private string canonicalizeCommandLineArgument(string s) { return s.replace("-", ""); }
private string canonicalizeIdentifier(string s) { return s.chomp("_").toLower(); }
private string identifierToCommandLineKeyword(string s) { return s.length ? s.chomp("_").splitByCamelCase.join("-").toLower() : "parameter"; }
private string identifierToCommandLineParam  (string s) { return s.length ? s.chomp("_").splitByCamelCase.join("-").toUpper() : "PARAMETER"; }
private string identifierToPlainText         (string s) { return s.length ? s.chomp("_").splitByCamelCase.join(" ").toLower() : "parameter"; }
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

/// Constructs the `funopt` usage string.
string getUsage(alias FUN)(string program)
{
	auto programName = getProgramName(program);
	enum formatString = getUsageFormatString!FUN();
	return formatString.format(programName);
}

/// Constructs the `funopt` usage format string.
/// `"%1$s"` is used instead of the program name.
string getUsageFormatString(alias FUN)()
{
	alias ParameterTypeTuple!FUN Params;
	enum names = [optionNames!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;
	enum ver = getVersionString!FUN;

	string result;
	static if (ver.length > 0)
		result = ver ~ "\n\n";
	result ~= "Usage: %1$s";
	enum inSynopsis(Param) = isParameter!Param || !optionHasDescription!Param;
	enum haveOmittedOptions = !allSatisfy!(inSynopsis, Params);
	static if (haveOmittedOptions)
	{
		enum haveRequiredOptions = (){
			bool result = false;
			foreach (i, Param; Params)
				static if (!inSynopsis!Param && Param.type == OptionType.option && is(defaults[i] == void))
					result = true;
			return result;
		}();
		static if (haveRequiredOptions)
			result ~= " OPTION...";
		else
			result ~= " [OPTION]...";
	}

	string getSwitchText(int i)()
	{
		alias Param = Params[i];
		static if (isParameter!Param)
			return names[i].identifierToCommandLineParam();
		else
		{
			string switchText = "--" ~ names[i].identifierToCommandLineKeyword();
			static if (is(Param == _OptionImpl!Args, Args...))
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
				// Parameters are optional if they have a default value or are Nullable
				static if (!is(defaults[i] == void) || isNullable!(OptionValueType!Param))
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
	static if (hasAttribute!(string, FUN))
	{
		enum description = getAttribute!(string, FUN);
		result ~= "\n" ~ description ~ "\n";
	}

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

/// Performs line wrapping for option descriptions.
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

debug(ae_unittest) unittest
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
"Usage: program OPTION... FILENAME [OUTPUT [EXTRA-FILES...]]

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

	// Test program descriptions
	@(`Refrobnicates the transmogrifier.`)
	void f8(Switch!"Be verbose." verbose){}

	usage = getUsage!f8("program");
	assert(usage ==
"Usage: program [OPTION]...

Refrobnicates the transmogrifier.

Options:
  --verbose  Be verbose.
", usage);

	// Test version in help output
	@Version("myapp 1.0.0")
	@(`Does something useful.`)
	void f9(Switch!"Be verbose." verbose){}

	usage = getUsage!f9("program");
	assert(usage ==
"myapp 1.0.0

Usage: program [OPTION]...

Does something useful.

Options:
  --verbose  Be verbose.
", usage);

	// Test Nullable options show correct placeholder
	void f10(
		Option!(Nullable!int, "Number of retries") retries,
		Option!(Nullable!string, "Output format") format,
	)
	{}

	usage = getUsage!f10("program");
	assert(usage ==
"Usage: program OPTION...

Options:
  --retries=N   Number of retries
  --format=STR  Output format
", usage);

	// Test Nullable positional parameters show as optional
	void f11(
		string requiredFile,
		Nullable!int optionalCount,
	)
	{}

	usage = getUsage!f11("program");
	assert(usage ==
"Usage: program REQUIRED-FILE [OPTIONAL-COUNT]
", usage);

	// Test Parameter!(Nullable!T) also shows as optional
	void f12(
		string requiredFile,
		Parameter!(Nullable!string, "Optional output path") outputPath,
	)
	{}

	usage = getUsage!f12("program");
	assert(usage ==
"Usage: program REQUIRED-FILE [OUTPUT-PATH]

Options:
  OUTPUT-PATH  Optional output path
", usage);
}

// ***************************************************************************

private string escapeRoff(string s)
{
	string result;
	foreach (c; s)
	{
		if (c == '\\')
			result ~= '\\';
		result ~= c;
	}
	return result;
}

/// Constructs a roff man page based on the `funopt` usage.
string generateManPage(alias FUN)(
	/// Program name, as it should appear in the header, synopsis etc.
	/// If not specified, the identifier name of FUN is used.
	string programName = null,
	/// Long description for the DESCRIPTION section.
	/// If not specified, we either use the function string UDA, or omit the section entirely.
	string longDescription = null,
	/// Short description for the NAME section.
	/// If not specified, generated from the function string UDA.
	string shortDescription = null,
	/// Additional sections (BUGS, AUTHORS) to add at the end.
	string footer = null,
	/// Manual section
	int section = 1,
)
{
	if (!programName)
		programName = __traits(identifier, FUN);

	string funDescription;
	static if (hasAttribute!(string, FUN))
		funDescription = getAttribute!(string, FUN).escapeRoff;

	string otherDescription;
	if (funDescription)
		otherDescription = funDescription;
	else
		otherDescription = longDescription;

	if (!shortDescription && otherDescription)
	{
		auto parts = (otherDescription ~ " ").findSplit(". ");
		if (!parts[2].length && otherDescription is longDescription)
			longDescription = null; // Move into shortDescription
		shortDescription = parts[0]
			.I!(s => toLower(s[0 .. 1]) ~ s[1 .. $]);
		shortDescription.skipOver(programName ~ " ");
	}

	// Bold the program name at the start of the description
	if (longDescription.skipOver(programName ~ " "))
		longDescription = ".B " ~ programName ~ "\n" ~ longDescription;

	alias ParameterTypeTuple!FUN Params;
	enum names = [optionNames!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	string result;
	result ~= ".\\\" Automatically generated by ae.utils.funopt. Do not edit.\n";
	result ~= ".TH %s %d\n".format(programName.toUpper, section);
	result ~= ".SH NAME\n";
	if (shortDescription)
		result ~= "%s \\- %s\n".format(programName, shortDescription);
	else
		result ~= "%s\n".format(programName);
	result ~= ".SH SYNOPSIS\n";
	result ~= "\\fB%s\\fP".format(programName);

	enum inSynopsis(Param) = isParameter!Param || !optionHasDescription!Param;
	enum haveOmittedOptions = !allSatisfy!(inSynopsis, Params);
	static if (haveOmittedOptions)
	{
		enum haveRequiredOptions = /*function bool*/(){
			bool result = false;
			foreach (i, Param; Params)
				static if (!inSynopsis!Param && Param.type == OptionType.option && is(defaults[i] == void))
					result = true;
			return result;
		}();
		static if (haveRequiredOptions)
			result ~= " \\fIOPTION\\fP...";
		else
			result ~= " [\\fIOPTION\\fP]...";
	}

	string getSwitchText(int i)()
	{
		alias Param = Params[i];
		static if (isParameter!Param)
			return "\\fI" ~ names[i].identifierToCommandLineParam() ~ "\\fP";
		else
		{
			string switchText = "\\fB--" ~ names[i].identifierToCommandLineKeyword() ~ "\\fP";
			static if (is(Param == _OptionImpl!Args, Args...))
				static if (Param.type == OptionType.option)
					switchText ~= (optionPlaceholder!Param.canFind('=') ? ' ' : '=') ~ "\\fI" ~ optionPlaceholder!Param ~ "\\fP";
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
				result ~= "\\fI" ~ names[i].identifierToCommandLineParam() ~ "\\fP";
			}
			else
			{
				flushOptional();
				result ~= " [" ~ getSwitchText!i() ~ "]";
			}
			static if (isOptionArray!Param)
				result ~= "...";
		}
	flushOptional();
	result ~= "\n";

	if (longDescription)
	{
		result ~= ".SH DESCRIPTION\n";
		result ~= longDescription;
		result ~= "\n";
	}

	enum haveDescriptions = anySatisfy!(optionHasDescription, Params);
	static if (haveDescriptions)
	{
		result ~= ".SH OPTIONS\n\n";

		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
			{
				result ~= ".TP\n";
				auto c = optionShorthand!Param;
				if (c)
					result ~= "\\fB-%s\\fP, ".format(c);
				auto description = optionDescription!Param
					.replace("\n", "\n\n")
					.escapeRoff;
				result ~= getSwitchText!i() ~ "\n" ~ description ~ "\n\n";
			}
	}

	result ~= footer;

	return result;
}

debug(ae_unittest) unittest
{
	@(`Frobnicates whatsits.`)
	void f1(
		Switch!("Enable verbose logging", 'v') verbose,
		Option!(int, "Number of tries") tries,
		Option!(int, "Seconds to wait each try", "SECS", 0, "timeout") t,
		in string filename,
		string output = "default",
		string[] extraFiles = null
	)
	{}

	auto man = generateManPage!f1();
	assert(man ==
`.\" Automatically generated by ae.utils.funopt. Do not edit.
.TH F1 1
.SH NAME
f1 \- frobnicates whatsits
.SH SYNOPSIS
\fBf1\fP \fIOPTION\fP... \fIFILENAME\fP [\fIOUTPUT\fP [\fIEXTRA-FILES\fP...]]
.SH OPTIONS

.TP
\fB-v\fP, \fB--verbose\fP
Enable verbose logging

.TP
\fB--tries\fP=\fIN\fP
Number of tries

.TP
\fB--timeout\fP=\fISECS\fP
Seconds to wait each try

`, man);
}

// ***************************************************************************

/// Dispatch the command line to a type's static methods, according to the
/// first parameter on the given command line (the "action").
/// String UDAs are used as usage documentation for generating --help output
/// (or when no action is specified).
auto funoptDispatch(alias Actions, FunOptConfig config = FunOptConfig.init, alias usageFun = defaultUsageFun, alias versionFun = defaultVersionFun)(string[] args)
{
	string program = args[0];

	auto funImpl(string action, string[] actionArguments = [])
	{
		action = action.canonicalizeCommandLineArgument();

		foreach (m; __traits(allMembers, Actions))
			static if (is(typeof(hasAttribute!(string, __traits(getMember, Actions, m)))))
			{
				alias member = I!(__traits(getMember, Actions, m));
				enum name = m.canonicalizeIdentifier();
				if (name == action)
				{
					auto args = [getProgramName(program) ~ " " ~ action] ~ actionArguments;
					static if (is(member == struct))
						return funoptDispatch!(member, config, usageFun, versionFun)(args);
					else
						return funopt!(member, config, usageFun, versionFun)(args);
				}
			}

		throw new GetOptException("Unknown action: " ~ action);
	}

	static if (hasAttribute!(string, Actions))
	{
		@Version(getVersionString!Actions)
		@(getAttribute!(string, Actions))
		auto fun(string action, string[] actionArguments = []) { return funImpl(action, actionArguments); }
	}
	else
	{
		@Version(getVersionString!Actions)
		auto fun(string action, string[] actionArguments = []) { return funImpl(action, actionArguments); }
	}

	static void myUsageFun(string usage) { usageFun(usage ~ funoptDispatchUsage!Actions()); }

	const FunOptConfig myConfig = (){
		auto c = config;
		c.getoptConfig ~= std.getopt.config.stopOnFirstNonOption;
		return c;
	}();
	return funopt!(fun, myConfig, myUsageFun, versionFun)(args);
}

/// Constructs the `funoptDispatch` usage string.
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

debug(ae_unittest) unittest
{
	@(`Test program.`)
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
	funoptDispatch!Actions(["program", "foo-bar", "new"]);

	static string usage;
	static void usageFun(string _usage) { usage = _usage; }
	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "--help"]);
	assert(usage == "Usage: unittest ACTION [ACTION-ARGUMENTS...]

Test program.

Actions:
  f1       Perform action f1
  f2       Perform complicated action f2
  foo-bar  An action sub-group
", usage);

	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "f1", "--help"]);
	assert(usage == "Usage: unittest f1 [--verbose]

Perform action f1
", usage);

	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "f2", "--help"]);
	assert(usage == "Usage: unittest f2

Perform complicated action f2

This action is complicated because of reasons.
", usage);

	funoptDispatch!(Actions, FunOptConfig.init, usageFun)(["unittest", "foo-bar", "--help"]);
	assert(usage == "Usage: unittest foobar ACTION [ACTION-ARGUMENTS...]

An action sub-group

Actions:
  new  Create a new foobar
", usage);
}

debug(ae_unittest) unittest
{
	// Test --version support with funoptDispatch
	static string versionOutput;
	static void testVersionFun(string ver) { versionOutput = ver; }

	@Version("mytool 2.0.0")
	@(`Test program.`)
	struct Actions
	{
		@(`Perform action f1`)
		static void f1() {}
	}

	versionOutput = null;
	funoptDispatch!(Actions, FunOptConfig.init, defaultUsageFun, testVersionFun)(["program", "--version"]);
	assert(versionOutput == "mytool 2.0.0", versionOutput);

	versionOutput = null;
	funoptDispatch!(Actions, FunOptConfig.init, defaultUsageFun, testVersionFun)(["program", "-V"]);
	assert(versionOutput == "mytool 2.0.0", versionOutput);

	// Without @Version, --version should not be recognized
	@(`Test program without version.`)
	struct ActionsNoVersion
	{
		@(`Perform action f1`)
		static void f1() {}
	}

	import std.exception : assertThrown;
	assertThrown!GetOptException(funoptDispatch!ActionsNoVersion(["program", "--version"]));
}
