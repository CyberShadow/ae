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

import std.array;
import std.conv;
import std.getopt;
import std.path;
import std.range;
import std.string;
import std.traits;
import std.typetuple;

import ae.utils.text;

private enum OptionType { switch_, option, parameter }

struct OptionImpl(OptionType type_, T_, string description_, char shorthand_, string placeholder_)
{
	enum type = type_;
	alias T = T_;
	enum description = description_;
	enum shorthand = shorthand_;
	enum placeholder = placeholder_;

	T value;
	alias value this;

	this(T value_)
	{
		value = value_;
	}
}

/// An on/off switch (e.g. --verbose). Does not have a value, other than its presence.
template Switch(string description=null, char shorthand=0)
{
	alias Switch = OptionImpl!(OptionType.switch_, bool, description, shorthand, null);
}

/// An option with a value (e.g. --tries N). The default placeholder depends on the type
/// (N for numbers, STR for strings).
template Option(T, string description=null, string placeholder=null, char shorthand=0)
{
	alias Option = OptionImpl!(OptionType.option, T, description, shorthand, placeholder);
}

/// An ordered parameter.
template Parameter(T, string description=null)
{
	alias Parameter = OptionImpl!(OptionType.parameter, T, description, 0, null);
}

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
		enum isParameter = true;
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

private enum bool optionHasDescription(T) = optionDescription!T !is null;

private template optionPlaceholder(T)
{
	static if (T.placeholder.length)
		enum optionPlaceholder = T.placeholder;
	else
	static if (is(OptionValueType!T : real))
		enum optionPlaceholder = "N";
	else
	static if (is(OptionValueType!T == string))
		enum optionPlaceholder = "STR";
	else
		enum optionPlaceholder = "X";
}

/// Parse the given arguments according to FUN's parameters, and call FUN.
/// Throws GetOptException on errors.
auto funopt(alias FUN)(string[] args)
{
	alias ParameterTypeTuple!FUN Params;
	Params values;
	enum names = [ParameterIdentifierTuple!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	foreach (i, defaultValue; defaults)
		static if (!is(defaultValue == void))
			values[i] = defaultValue;

	enum structFields = Params.length.iota.map!(n => "string selector%d; OptionValueType!(Params[%d])* value%d;\n".format(n, n, n)).join();

	static struct GetOptArgs { mixin(structFields); }
	GetOptArgs getOptArgs;

	static string optionSelector(int i)()
	{
		string[] variants;
		auto shorthand = optionShorthand!(Params[i]);
		if (shorthand)
			variants ~= [shorthand];
		enum words = names[i].splitByCamelCase();
		variants ~= words.join().toLower();
		if (words.length > 1)
			variants ~= words.join("-").toLower();
		return variants.join("|");
	}

	foreach (i, ref value; values)
	{
		enum selector = optionSelector!i();
		mixin("getOptArgs.selector%d = selector;".format(i));
		mixin("getOptArgs.value%d = optionValue(values[%d]);".format(i, i));
	}

	bool help;

	getopt(args,
		std.getopt.config.bundling,
		"h|help", &help,
		getOptArgs.tupleof);

	if (help)
	{
		import std.stdio;
		stderr.writeln(getUsage!FUN(args[0]));
		return cast(ReturnType!FUN)0;
	}

	args = args[1..$];

	foreach (i, ref value; values)
	{
		alias T = Params[i];
		static if (isParameter!T)
		{
			static if (is(T == string[]))
			{
				values[i] = args;
				args = null;
			}
			else
			{
				if (args.length)
				{
					values[i] = to!T(args[0]);
					args = args[1..$];
				}
				else
				{
					static if (is(defaults[i] == void))
						throw new GetOptException("No " ~ names[i] ~ " specified.");
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
	void f1(Switch!() verbose, Option!int tries, string filename)
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
}

string getUsage(alias FUN)(string programName)
{
	programName = programName.baseName();
	version(Windows)
	{
		programName = programName.toLower();
		if (programName.extension == ".exe")
			programName = programName.stripExtension();
	}

	enum formatString = getUsageFormatString!FUN();
	return formatString.format(programName);
}

string getUsageFormatString(alias FUN)()
{
	alias ParameterTypeTuple!FUN Params;
	enum names = [ParameterIdentifierTuple!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	string result = "Usage: %s";
	enum haveNonParameters = !allSatisfy!(isParameter, Params);
	static if (haveNonParameters)
		result ~= " [OPTION]...";

	foreach (i, Param; Params)
		if (isParameter!Param)
		{
			result ~= " ";
			static if (!is(defaults[i] == void))
				result ~= "[";
			result ~= toUpper(names[i].splitByCamelCase().join("-"));
			static if (!is(defaults[i] == void))
				result ~= "]";
			static if (is(OptionValueType!Param == string[]))
				result ~= "...";
		}

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
				string longName = names[i].splitByCamelCase().join("-");
				static if (Param.type == OptionType.option)
					longName ~= "=" ~ optionPlaceholder!Param;
				if (haveShorthands)
				{
					auto c = optionShorthand!Param;
					if (c)
						selectors[i] = "-%s, --%s".format(c, longName);
					else
						selectors[i] = "    --%s".format(longName);
				}
				else
					selectors[i] = "--" ~ longName;
				longestSelector = max(longestSelector, selectors[i].length);
			}

		result ~= "\nOptions:\n";
		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
			{
				result ~= wrap(
					optionDescription!Param,
					79,
					"  %-*s  ".format(longestSelector, selectors[i]),
					" ".replicate(2 + longestSelector + 2)
				);
			}
	}

	return result;
}

unittest
{
	void f1(
		Switch!("Enable verbose logging", 'v') verbose,
		Option!(int, "Number of tries") tries,
		Option!(int, "Seconds to wait each try", "SECS") timeout,
		string filename,
		string output = "default",
		string[] extraFiles = null
	)
	{}

	auto usage = getUsage!f1("program");
	assert(usage ==
"Usage: program [OPTION]... FILENAME [OUTPUT] [EXTRA-FILES]...

Options:
  -v, --verbose       Enable verbose logging
      --tries=N       Number of tries
      --timeout=SECS  Seconds to wait each try
", usage);
}
