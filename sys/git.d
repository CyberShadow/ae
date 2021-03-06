/**
 * Wrappers for the git command-line tools.
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

module ae.sys.git;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.string;
import std.typecons : RefCounted;
import std.utf;

import ae.sys.cmd;
import ae.sys.file;
import ae.utils.aa;
import ae.utils.array;
import ae.utils.meta;
import ae.utils.text;

struct Repository
{
	string path;
	string gitDir;

	string[string] environment;
	string[] commandPrefix;

	static string[] globalOptions; // per-thread

	this(string path)
	{
		path = path.absolutePath();
		enforce(path.exists, "Repository path does not exist: " ~ path);
		gitDir = path.buildPath(".git");
		if (gitDir.exists && gitDir.isFile)
			gitDir = path.buildNormalizedPath(gitDir.readText().strip()[8..$]);
		//path = path.replace(`\`, `/`);
		this.path = path;
		this.commandPrefix = ["git",
			"-c", "core.autocrlf=false",
			"-c", "gc.autoDetach=false",
			"-C", path
		] ~ globalOptions;
		version (Windows) {} else
			this.environment["GIT_CONFIG_NOSYSTEM"] = "1";
		this.environment["HOME"] = gitDir;
		this.environment["XDG_CONFIG_HOME"] = gitDir;
	}

	invariant()
	{
		assert(environment !is null, "Not initialized");
	}

	// Have just some primitives here.
	// Higher-level functionality can be added using UFCS.
	void   run  (string[] args...) const { return .run  (commandPrefix ~ args, environment, path); }
	string query(string[] args...) const { return .query(commandPrefix ~ args, environment, path).chomp(); }
	bool   check(string[] args...) const { return spawnProcess(commandPrefix ~ args, environment, Config.none, path).wait() == 0; }
	auto   pipe (string[] args, Redirect redirect)
	                               const { return pipeProcess(commandPrefix ~ args, redirect, environment, Config.none, path); }
	auto   pipe (string[] args...) const { return pipe(args, Redirect.stdin | Redirect.stdout); }

	/// Certain git commands (notably, bisect) must
	/// be run in the repository's root directory.
	private string workPath(string cmd) const
	{
		switch (cmd)
		{
			case "bisect":
			case "submodule":
				return path;
			default:
				return null;
		}
	}

	History getHistory(string[] extraRefs = null) const
	{
		History history;

		Commit* getCommit(Hash hash)
		{
			auto pcommit = hash in history.commits;
			return pcommit ? *pcommit : (history.commits[hash] = new Commit(history.numCommits++, hash));
		}

		Commit* commit;
		string currentBlock;

		foreach (line; query([`log`, `--all`, `--pretty=raw`] ~ extraRefs).split('\n'))
		{
			if (!line.length)
			{
				if (currentBlock)
					currentBlock = null;
				continue;
			}

			if (currentBlock)
			{
				enforce(line.startsWith(" "), "Expected " ~ currentBlock ~ " line in git log");
				continue;
			}

			if (line.startsWith("commit "))
			{
				auto hash = line[7..$].toCommitHash();
				commit = getCommit(hash);
			}
			else
			if (line.startsWith("tree "))
				continue;
			else
			if (line.startsWith("parent "))
			{
				auto hash = line[7..$].toCommitHash();
				auto parent = getCommit(hash);
				commit.parents ~= parent;
				parent.children ~= commit;
			}
			else
			if (line.startsWith("author "))
				commit.author = line[7..$];
			else
			if (line.startsWith("committer "))
			{
				commit.committer = line[10..$];
				commit.time = line.split(" ")[$-2].to!int();
			}
			else
			if (line.startsWith("    "))
				commit.message ~= line[4..$];
			else
			if (line.startsWith("gpgsig "))
				currentBlock = "GPG signature";
			else
			if (line.startsWith("mergetag "))
				currentBlock = "Tag merge";
			else
				enforce(false, "Unknown line in git log: " ~ line);
		}

		foreach (line; query([`show-ref`, `--dereference`]).splitLines())
		{
			auto h = line[0..40].toCommitHash();
			if (h in history.commits)
				history.refs[line[41..$]] = h;
		}

		return history;
	}

	struct ObjectReaderImpl
	{
		ProcessPipes pipes;

		GitObject read(string name)
		{
			pipes.stdin.writeln(name);
			pipes.stdin.flush();

			auto headerLine = pipes.stdout.safeReadln().strip();
			auto header = headerLine.split(" ");
			enforce(header.length == 3, "Malformed header during cat-file: " ~ headerLine);
			auto hash = header[0].toCommitHash();

			GitObject obj;
			obj.hash = hash;
			obj.type = header[1];
			auto size = to!size_t(header[2]);
			if (size)
			{
				auto data = new ubyte[size];
				auto read = pipes.stdout.rawRead(data);
				enforce(read.length == size, "Unexpected EOF during cat-file");
				obj.data = data.assumeUnique();
			}

			char[1] lf;
			pipes.stdout.rawRead(lf[]);
			enforce(lf[0] == '\n', "Terminating newline expected");

			return obj;
		}

		GitObject read(Hash hash)
		{
			auto obj = read(hash.toString());
			enforce(obj.hash == hash, "Unexpected object during cat-file");
			return obj;
		}

		~this()
		{
			pipes.stdin.close();
			enforce(pipes.pid.wait() == 0, "git cat-file exited with failure");
		}
	}
	alias ObjectReader = RefCounted!ObjectReaderImpl;

	/// Spawn a cat-file process which can read git objects by demand.
	ObjectReader createObjectReader()
	{
		auto pipes = this.pipe(`cat-file`, `--batch`);
		return ObjectReader(pipes);
	}

	/// Run a batch cat-file query.
	GitObject[] getObjects(Hash[] hashes)
	{
		GitObject[] result;
		result.reserve(hashes.length);
		auto reader = createObjectReader();

		foreach (hash; hashes)
			result ~= reader.read(hash);

		return result;
	}

	struct ObjectWriterImpl
	{
		bool initialized;
		ProcessPipes pipes;

		this(ProcessPipes pipes)
		{
			this.pipes = pipes;
			initialized = true;
		}

		Hash write(in void[] data)
		{
			import std.random;
			auto p = NamedPipe("ae-sys-git-writeObjects-%d".format(uniform!ulong));
			pipes.stdin.writeln(p.fileName);
			pipes.stdin.flush();

			auto f = p.connect();
			f.rawWrite(data);
			f.flush();
			f.close();

			return pipes.stdout.safeReadln().strip().toCommitHash();
		}

		~this()
		{
			if (initialized)
			{
				pipes.stdin.close();
				enforce(pipes.pid.wait() == 0, "git hash-object exited with failure");
				initialized = false;
			}
		}
	}
	alias ObjectWriter = RefCounted!ObjectWriterImpl;

	struct ObjectMultiWriterImpl
	{
		Repository* repo;
		ObjectWriter treeWriter, blobWriter, commitWriter;

		Hash write(in GitObject obj)
		{
			ObjectWriter* pwriter;
			switch (obj.type) // https://issues.dlang.org/show_bug.cgi?id=14595
			{
				case "tree"  : pwriter = &treeWriter  ; break;
				case "blob"  : pwriter = &blobWriter  ; break;
				case "commit": pwriter = &commitWriter; break;
				default: throw new Exception("Unknown object type: " ~ obj.type);
			}
			if (!pwriter.initialized)
				*pwriter = ObjectWriter(repo.pipe(`hash-object`, `-t`, obj.type, `-w`, `--stdin-paths`));
			return pwriter.write(obj.data);
		}
	}
	alias ObjectMultiWriter = RefCounted!ObjectMultiWriterImpl;

	/// Spawn a hash-object process which can hash and write git objects on the fly.
	ObjectWriter createObjectWriter(string type)
	{
		auto pipes = this.pipe(`hash-object`, `-t`, type, `-w`, `--stdin-paths`);
		return ObjectWriter(pipes);
	}

	/// ditto
	ObjectMultiWriter createObjectWriter()
	{
		return ObjectMultiWriter(&this);
	}

	/// Batch-write the given objects to the database.
	/// The hashes are saved to the "hash" fields of the passed objects.
	void writeObjects(GitObject[] objects)
	{
		string[] allTypes = objects.map!(obj => obj.type).toSet().keys;
		foreach (type; allTypes)
		{
			auto writer = createObjectWriter(type);
			foreach (ref obj; objects)
				if (obj.type == type)
					obj.hash = writer.write(obj.data);
		}
	}

	/// Extract a commit's tree to a given directory
	void exportCommit(string commit, string path, ObjectReader reader, bool delegate(string) pathFilter = null)
	{
		exportTree(reader.read(commit).parseCommit().tree, path, reader, pathFilter);
	}

	/// Extract a tree to a given directory
	void exportTree(Hash treeHash, string path, ObjectReader reader, bool delegate(string) pathFilter = null)
	{
		void exportSubTree(Hash treeHash, string[] subPath)
		{
			auto tree = reader.read(treeHash).parseTree();
			foreach (entry; tree)
			{
				auto entrySubPath = subPath ~ entry.name;
				if (pathFilter && !pathFilter(entrySubPath.join("/")))
					continue;
				auto entryPath = buildPath([path] ~ entrySubPath);
				switch (entry.mode)
				{
					case octal!100644: // file
					case octal!100755: // executable file
						std.file.write(entryPath, reader.read(entry.hash).data);
						version (Posix)
						{
							// Make executable
							if (entry.mode == octal!100755)
								entryPath.setAttributes(entryPath.getAttributes | ((entryPath.getAttributes & octal!444) >> 2));
						}
						break;
					case octal! 40000: // tree
						mkdirRecurse(entryPath);
						exportSubTree(entry.hash, entrySubPath);
						break;
					case octal!160000: // submodule
						mkdirRecurse(entryPath);
						break;
					default:
						throw new Exception("Unknown git file mode: %o".format(entry.mode));
				}
			}
		}
		exportSubTree(treeHash, null);
	}

	/// Import a directory tree into the object store, and return the new tree object's hash.
	Hash importTree(string path, ObjectMultiWriter writer, bool delegate(string) pathFilter = null)
	{
		static // Error: variable ae.sys.git.Repository.importTree.writer has scoped destruction, cannot build closure
		Hash importSubTree(string path, string subPath, ref ObjectMultiWriter writer, bool delegate(string) pathFilter)
		{
			auto entries = subPath
				.dirEntries(SpanMode.shallow)
				.filter!(de => !pathFilter || pathFilter(de.relativePath(path)))
				.map!(de =>
					de.isDir
					? GitObject.TreeEntry(
						octal!40000,
						de.baseName,
						importSubTree(path, buildPath(subPath, de.baseName), writer, pathFilter)
					)
					: GitObject.TreeEntry(
						isVersion!`Posix` && (de.attributes & octal!111) ? octal!100755 : octal!100644,
						de.baseName,
						writer.write(GitObject(Hash.init, "blob", cast(immutable(ubyte)[])read(de.name)))
					)
				)
				.array
				.sort!((a, b) => a.sortName < b.sortName).release
			;
			return writer.write(GitObject.createTree(entries));
		}
		return importSubTree(path, path, writer, pathFilter);
	}

	struct RefWriterImpl
	{
		bool initialized;
		ProcessPipes pipes;

		this(ProcessPipes pipes)
		{
			this.pipes = pipes;
			initialized = true;
		}

		private void op(string op)
		{
			pipes.stdin.write(op, '\0');
			pipes.stdin.flush();
		}

		private void op(string op, bool noDeref, string refName, Hash*[] hashes...)
		{
			if (noDeref)
				pipes.stdin.write("option no-deref\0");
			pipes.stdin.write(op, " ", refName, '\0');
			foreach (hash; hashes)
			{
				if (hash)
					pipes.stdin.write((*hash).toString());
				pipes.stdin.write('\0');
			}
			pipes.stdin.flush();
		}

		void update   (string refName, Hash newValue               , bool noDeref = false) { op("update", noDeref, refName, &newValue, null     ); }
		void update   (string refName, Hash newValue, Hash oldValue, bool noDeref = false) { op("update", noDeref, refName, &newValue, &oldValue); }
		void create   (string refName, Hash newValue               , bool noDeref = false) { op("create", noDeref, refName, &newValue           ); }
		void deleteRef(string refName                              , bool noDeref = false) { op("delete", noDeref, refName,            null     ); }
		void deleteRef(string refName,                Hash oldValue, bool noDeref = false) { op("delete", noDeref, refName,            &oldValue); }
		void verify   (string refName                              , bool noDeref = false) { op("verify", noDeref, refName,            null     ); }
		void verify   (string refName,                Hash oldValue, bool noDeref = false) { op("verify", noDeref, refName,            &oldValue); }
		void start    () { op("start"); }
		void prepare  () { op("prepare"); }
		void commit   () { op("commit"); }
		void abort    () { op("abort"); }

		~this()
		{
			if (initialized)
			{
				pipes.stdin.close();
				enforce(pipes.pid.wait() == 0, "git update-ref exited with failure");
				initialized = false;
			}
		}
	}
	alias RefWriter = RefCounted!RefWriterImpl;

	/// Spawn a update-ref process which can update git refs on the fly.
	RefWriter createRefWriter()
	{
		auto pipes = this.pipe(`update-ref`, `-z`, `--stdin`);
		return RefWriter(pipes);
	}
}

struct GitObject
{
	Hash hash;
	string type;
	immutable(ubyte)[] data;

	static GitObject createBlob(immutable(ubyte)[] data)
	{
		return GitObject(Hash.init, "blob", data);
	}

	struct ParsedCommit
	{
		Hash tree;
		Hash[] parents;
		string author, committer; /// entire lines - name, email and date
		string[] message, gpgsig;

		@property Authorship parsedAuthor() { return parseAuthorship(author); }
		@property Authorship parsedCommitter() { return parseAuthorship(committer); }
		@property void parsedAuthor(Authorship authorship) { author = authorship.toString(); }
		@property void parsedCommitter(Authorship authorship) { committer = authorship.toString(); }
	}

	ParsedCommit parseCommit()
	{
		enforce(type == "commit", "Wrong object type");
		ParsedCommit result;
		auto lines = (cast(string)data).split('\n');
		while (lines.length)
		{
			auto line = lines.shift();
			if (line == "")
			{
				result.message = lines;
				break; // commit message begins
			}
			auto parts = line.findSplit(" ");
			auto field = parts[0];
			line = parts[2];
			switch (field)
			{
				case "tree":
					result.tree = line.toCommitHash();
					break;
				case "parent":
					result.parents ~= line.toCommitHash();
					break;
				case "author":
					result.author = line;
					break;
				case "committer":
					result.committer = line;
					break;
				case "gpgsig":
				{
					auto p = lines.countUntil!(line => !line.startsWith(" "));
					if (p < 0)
						p = lines.length;
					result.gpgsig = [line] ~ lines[0 .. p].apply!(each!((ref line) => line.skipOver(" ").enforce("gpgsig line without leading space")));
					lines = lines[p .. $];
					break;
				}
				default:
					throw new Exception("Unknown commit field: " ~ field ~ "\n" ~ cast(string)data);
			}
		}
		return result;
	}

	static GitObject createCommit(ParsedCommit commit)
	{
		auto s = "tree %s\n%-(parent %s\n%|%)author %s\ncommitter %s\n\n%-(%s\n%)".format(
				commit.tree.toString(),
				commit.parents.map!(ae.sys.git.toString),
				commit.author,
				commit.committer,
				commit.message,
			);
		return GitObject(Hash.init, "commit", cast(immutable(ubyte)[])s);
	}

	struct TreeEntry
	{
		uint mode;
		string name;
		Hash hash;

		@property string sortName() { return (mode & octal!40000) ? name ~ "/" : name; }
	}

	TreeEntry[] parseTree()
	{
		enforce(type == "tree", "Wrong object type");
		TreeEntry[] result;
		auto rem = data;
		while (rem.length)
		{
			auto si = rem.countUntil(' ');
			auto zi = rem.countUntil(0);
			auto ei = zi + 1 + Hash.sizeof;
			auto str = cast(string)rem[0..zi];
			enforce(0 < si && si < zi && ei <= rem.length, "Malformed tree entry:\n" ~ hexDump(rem));
			result ~= TreeEntry(str[0..si].to!uint(8), str[si+1..zi], cast(Hash)rem[zi+1..ei][0..20]); // https://issues.dlang.org/show_bug.cgi?id=13112
			rem = rem[ei..$];
		}
		return result;
	}

	static GitObject createTree(TreeEntry[] entries)
	{
		auto buf = appender!(immutable(ubyte)[]);
		foreach (entry; entries)
		{
			buf.formattedWrite("%o %s\0", entry.mode, entry.name);
			buf.put(entry.hash[]);
		}
		return GitObject(Hash.init, "tree", buf.data);
	}
}

struct History
{
	Commit*[Hash] commits;
	uint numCommits = 0;
	Hash[string] refs;
}

alias ubyte[20] Hash;

struct Commit
{
	uint id;
	Hash hash;
	uint time;
	string author, committer;
	string[] message;
	Commit*[] parents, children;

	@property Authorship parsedAuthor() { return parseAuthorship(author); }
	@property Authorship parsedCommitter() { return parseAuthorship(committer); }
	@property void parsedAuthor(Authorship authorship) { author = authorship.toString(); }
	@property void parsedCommitter(Authorship authorship) { committer = authorship.toString(); }
}

struct Authorship
{
	string name;
	string email;
	string date; // use `"U O"` ae.utils.time format to parse/format
	string toString() const { return name ~ " <" ~ email ~ "> " ~ date; }
}
static Authorship parseAuthorship(string authorship)
{
	Authorship result;
	auto parts1 = authorship.findSplit(" <");
	auto parts2 = parts1[2].findSplit("> ");
	result.name = parts1[0];
	result.email = parts2[0];
	result.date = parts2[2];
	return result;
}

Hash toCommitHash(in char[] hash)
{
	enforce(hash.length == 40, "Bad hash length: " ~ hash);
	ubyte[20] result;
	foreach (i, ref b; result)
		b = to!ubyte(hash[i*2..i*2+2], 16);
	return result;
}

unittest
{
	assert(toCommitHash("0123456789abcdef0123456789ABCDEF01234567") == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67]);
}

string toString(ref Hash hash) pure
{
	char[40] buf = hash.toLowerHex();
	return buf[].idup;
}

unittest
{
	Hash hash = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67];
	assert(hash.toString() == "0123456789abcdef0123456789abcdef01234567");
}

/// Tries to match the default destination of `git clone`.
string repositoryNameFromURL(string url)
{
	return url
		.split(":")[$-1]
		.split("/")[$-1]
		.chomp(".git");
}

unittest
{
	assert(repositoryNameFromURL("https://github.com/CyberShadow/ae.git") == "ae");
	assert(repositoryNameFromURL("git@example.com:ae.git") == "ae");
}
