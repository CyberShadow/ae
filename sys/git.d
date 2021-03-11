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

import core.stdc.time : time_t;

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

/// Represents an object which allows manipulating a Git repository.
struct Git
{
	/// Create an object which allows manipulating a Git repository.
	/// Because the location of $GIT_DIR (the .git directory) is queried at construction,
	/// the repository must exist.
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

	/// The path to the repository's work tree.
	string path;

	/// The path to the repository's .git directory.
	string gitDir;

	/// The environment that commands will be executed with.
	/// This field and `commandPrefix` are populated at construction,
	/// but may be modified afterwards, before any operations.
	string[string] environment;

	/// The prefix to apply to all executed commands.
	/// Includes the "git" program, and all of its top-level options.
	string[] commandPrefix;

	/// Global options to add to `commandPrefix` during construction.
	static string[] globalOptions; // per-thread

	invariant()
	{
		assert(environment !is null, "Not initialized");
	}

	// Have just some primitives here.
	// Higher-level functionality can be added using UFCS.

	/// Run a command. Throw if it fails.
	void   run  (string[] args...) const { return .run  (commandPrefix ~ args, environment, path); }
	/// Run a command, and return its output, sans trailing newline.
	string query(string[] args...) const { return .query(commandPrefix ~ args, environment, path).chomp(); }
	/// Run a command, and return true if it succeeds.
	bool   check(string[] args...) const { return spawnProcess(commandPrefix ~ args, environment, Config.none, path).wait() == 0; }
	/// Run a command with pipe redirections. Return the pipes.
	auto   pipe (string[] args, Redirect redirect)
	                               const { return pipeProcess(commandPrefix ~ args, redirect, environment, Config.none, path); }
	auto   pipe (string[] args...) const { return pipe(args, Redirect.stdin | Redirect.stdout); } /// ditto

	/// A parsed Git author/committer line.
	struct Authorship
	{
		/// Format string which can be used with
		/// ae.utils.time to parse or format Git dates.
		enum dateFormat = "U O";

		string name; /// Name (without email).
		string email; /// Email address (without the < / > delimiters).
		string date; /// Raw date. Use `dateFormat` with ae.utils.time to parse.

		/// Parse from a raw author/committer line.
		this(string authorship)
		{
			auto parts1 = authorship.findSplit(" <");
			auto parts2 = parts1[2].findSplit("> ");
			this.name = parts1[0];
			this.email = parts2[0];
			this.date = parts2[2];
		}

		/// Construct from fields.
		this(string name, string email, string date)
		{
			this.name = name;
			this.email = email;
			this.date = date;
		}

		/// Convert to a raw author/committer line.
		string toString() const { return name ~ " <" ~ email ~ "> " ~ date; }
	}

	/// A convenience function which loads the entire Git history into a graph.
	struct History
	{
		/// An entry corresponding to a Git commit in this `History` object.
		struct Commit
		{
			size_t index; /// Index in this `History` instance.
			CommitID oid;  /// The commit hash.
			time_t time;  /// UNIX time.
			string author, committer; /// Raw author/committer lines. Use Authorship to parse.
			string[] message; /// Commit message lines.
			Commit*[] parents, children; /// Edges to neighboring commits. Children order is unspecified.

			deprecated alias hash = oid;
			deprecated alias id = index;

			/// Get or set author/committer lines as parsed object.
			@property Authorship parsedAuthor() { return Authorship(author); }
			@property Authorship parsedCommitter() { return Authorship(committer); } /// ditto
			@property void parsedAuthor(Authorship authorship) { author = authorship.toString(); } /// ditto
			@property void parsedCommitter(Authorship authorship) { committer = authorship.toString(); } /// ditto
		}

		Commit*[CommitID] commits; /// All commits in this `History` object.
		size_t numCommits = 0; /// Number of commits in `commits`.
		CommitID[string] refs; /// A map of full Git refs (e.g. "refs/heads/master") to their commit IDs.
	}

	/// ditto
	History getHistory() const
	{
		History history;

		History.Commit* getCommit(CommitID oid)
		{
			auto pcommit = oid in history.commits;
			return pcommit ? *pcommit : (history.commits[oid] = new History.Commit(history.numCommits++, oid));
		}

		History.Commit* commit;
		string currentBlock;

		foreach (line; query([`log`, `--all`, `--pretty=raw`]).split('\n'))
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
				auto hash = CommitID(line[7..$]);
				commit = getCommit(hash);
			}
			else
			if (line.startsWith("tree "))
				continue;
			else
			if (line.startsWith("parent "))
			{
				auto hash = CommitID(line[7..$]);
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
			auto h = CommitID(line[0..40]);
			enforce(h in history.commits, "Ref commit not in log: " ~ line);
			history.refs[line[41..$]] = h;
		}

		return history;
	}

	deprecated History getHistory(string[] /*extraRefs*/) const { return getHistory(); }

	// Low-level pipes

	/// Git object identifier (identifies blobs, trees, commits, etc.)
	struct OID
	{
		/// Watch me: new hash algorithms may be supported in the future.
		ubyte[20] sha1;

		deprecated alias sha1 this;

		/// Construct from an ASCII string.
		this(in char[] sha1)
		{
			enforce(sha1.length == 40, "Bad SHA-1 length: " ~ sha1);
			foreach (i, ref b; this.sha1)
				b = to!ubyte(sha1[i*2..i*2+2], 16);
		}

		/// Convert to the ASCII representation.
		string toString() pure const
		{
			char[40] buf = sha1.toLowerHex();
			return buf[].idup;
		}

		unittest
		{
			OID oid;
			oid.sha1 = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67];
			assert(oid.toString() == "0123456789abcdef0123456789abcdef01234567");
		}
	}

	private mixin template TypedObjectID(string type_)
	{
		/// As in git-hash-object's -t parameter.
		enum type = type_;

		OID oid; /// The generic object identifier.
		alias oid this;

		this(OID oid) { this.oid = oid; } /// Construct from a generic identifier.
		this(in char[] hash) { oid = OID(hash); } /// Construct from an ASCII string.
		string toString() pure const { return oid.toString(); } /// Convert to the ASCII representation.

		// Disable implicit conversion directly between different kinds of OIDs.
		static if (!is(typeof(this) == CommitID)) @disable this(CommitID);
		static if (!is(typeof(this) == TreeID)) @disable this(TreeID);
		static if (!is(typeof(this) == BlobID)) @disable this(BlobID);
	}
	/// Strong typed OIDs to distinguish which kind of object they identify.
	struct CommitID { mixin TypedObjectID!"commit"; }
	struct TreeID   { mixin TypedObjectID!"tree"  ; } /// ditto
	struct BlobID   { mixin TypedObjectID!"blob"  ; } /// ditto

	/// The parsed representation of a raw Git object.
	struct Object
	{
		/// Object identifier. Will be OID.init initially.
		OID oid;

		/// Object type, as in git-hash-object's -t parameter.
		string type;

		/// The raw data contained in this object.
		immutable(ubyte)[] data;

		deprecated alias hash = oid;

		/// Create a blob object (i.e., a file) from raw bytes.
		static Object createBlob(immutable(ubyte)[] data)
		{
			return Object(OID.init, "blob", data);
		}

		/// Represents a parsed Git commit object.
		struct ParsedCommit
		{
			/// The Git OID of this commit's tree.
			TreeID tree;

			/// This commit's parents.
			CommitID[] parents;

			/// Raw author/committer lines.
			string author, committer;

			/// Commit message lines.
			string[] message;

			/// GPG signature certifying this commit, if any.
			string[] gpgsig;

			/// Get or set author/committer lines as parsed object.
			@property Authorship parsedAuthor() { return Authorship(author); }
			@property Authorship parsedCommitter() { return Authorship(committer); } /// ditto
			@property void parsedAuthor(Authorship authorship) { author = authorship.toString(); } /// ditto
			@property void parsedCommitter(Authorship authorship) { committer = authorship.toString(); } /// ditto
		}

		/// Parse this raw Git object as a commit.
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
						result.tree = TreeID(line);
						break;
					case "parent":
						result.parents ~= CommitID(line);
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

		/// Format a Git commit into a raw Git object.
		static Object createCommit(in ParsedCommit commit)
		{
			auto s = "tree %s\n%-(parent %s\n%|%)author %s\ncommitter %s\n\n%-(%s\n%)".format(
					commit.tree.toString(),
					commit.parents.map!((in ref CommitID oid) => oid.toString()),
					commit.author,
					commit.committer,
					commit.message,
				);
			return Object(OID.init, "commit", cast(immutable(ubyte)[])s);
		}

		/// Represents an entry in a parsed Git commit object.
		struct TreeEntry
		{
			uint mode;     /// POSIX mode. E.g., will be 100644 or 100755 for files.
			string name;   /// Name within this subtree.
			OID hash;      /// Object identifier of the entry's contents. Could be a tree or blob ID.

			/// Sort key to be used when constructing a tree object.
			@property string sortName() const { return (mode & octal!40000) ? name ~ "/" : name; }

			int opCmp(ref const TreeEntry b) const
			{
				return cmp(sortName, b.sortName);
			}
		}

		/// Parse this raw Git object as a tree.
		TreeEntry[] parseTree()
		{
			enforce(type == "tree", "Wrong object type");
			TreeEntry[] result;
			auto rem = data;
			while (rem.length)
			{
				auto si = rem.countUntil(' ');
				auto zi = rem.countUntil(0);
				auto ei = zi + 1 + OID.sha1.length;
				auto str = cast(string)rem[0..zi];
				enforce(0 < si && si < zi && ei <= rem.length, "Malformed tree entry:\n" ~ hexDump(rem));
				OID oid;
				oid.sha1 = rem[zi+1..ei][0..OID.sha1.length];
				result ~= TreeEntry(str[0..si].to!uint(8), str[si+1..zi], oid); // https://issues.dlang.org/show_bug.cgi?id=13112
				rem = rem[ei..$];
			}
			return result;
		}

		/// Format a Git tree into a raw Git object.
		/// Tree entries must be sorted lexicographically by name.
		static Object createTree(in TreeEntry[] entries)
		{
			auto buf = appender!(immutable(ubyte)[]);
			foreach (entry; entries)
			{
				buf.formattedWrite("%o %s\0", entry.mode, entry.name);
				buf.put(entry.hash[]);
			}
			return Object(OID.init, "tree", buf.data);
		}
	}

	/// Spawn a cat-file process which can read git objects by demand.
	struct ObjectReaderImpl
	{
		private ProcessPipes pipes;

		/// Read an object by its identifier.
		Object read(string name)
		{
			pipes.stdin.writeln(name);
			pipes.stdin.flush();

			auto headerLine = pipes.stdout.safeReadln().strip();
			auto header = headerLine.split(" ");
			enforce(header.length == 3, "Malformed header during cat-file: " ~ headerLine);
			auto oid = OID(header[0]);

			Object obj;
			obj.oid = oid;
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

		/// ditto
		Object read(OID oid)
		{
			auto obj = read(oid.toString());
			enforce(obj.oid == oid, "Unexpected object during cat-file");
			return obj;
		}

		~this()
		{
			pipes.stdin.close();
			enforce(pipes.pid.wait() == 0, "git cat-file exited with failure");
		}
	}
	alias ObjectReader = RefCounted!ObjectReaderImpl; /// ditto

	ObjectReader createObjectReader() /// ditto
	{
		auto pipes = this.pipe(`cat-file`, `--batch`);
		return ObjectReader(pipes);
	}

	/// Run a batch cat-file query.
	Object[] getObjects(OID[] hashes)
	{
		Object[] result;
		result.reserve(hashes.length);
		auto reader = createObjectReader();

		foreach (hash; hashes)
			result ~= reader.read(hash);

		return result;
	}

	/// Spawn a hash-object process which can hash and write git objects on the fly.
	struct ObjectWriterImpl
	{
		private bool initialized;
		private ProcessPipes pipes;

		/*private*/ this(ProcessPipes pipes)
		{
			this.pipes = pipes;
			initialized = true;
		}

		/// Write a raw Git object of this writer's type, and return the OID.
		OID write(in ubyte[] data)
		{
			import std.random : uniform;
			auto p = NamedPipe("ae-sys-git-writeObjects-%d".format(uniform!ulong));
			pipes.stdin.writeln(p.fileName);
			pipes.stdin.flush();

			auto f = p.connect();
			f.rawWrite(data);
			f.flush();
			f.close();

			return OID(pipes.stdout.safeReadln().strip());
		}

		deprecated OID write(in void[] data) { return write(cast(const(ubyte)[]) data); }

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
	alias ObjectWriter = RefCounted!ObjectWriterImpl; /// ditto

	ObjectWriter createObjectWriter(string type) /// ditto
	{
		auto pipes = this.pipe(`hash-object`, `-t`, type, `-w`, `--stdin-paths`);
		return ObjectWriter(pipes);
	}

	struct ObjectMultiWriterImpl /// ditto
	{
		private Git* repo;

		/// The ObjectWriter instances for each individual type.
		ObjectWriter treeWriter, blobWriter, commitWriter;

		/// Write a Git object, and return the OID.
		OID write(in Object obj)
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

		/// Format and write a Git object, and return the OID.
		CommitID write(in Object.ParsedCommit commit) { return CommitID(write(Object.createCommit(commit))); }
		TreeID   write(in Object.TreeEntry[] entries) { return TreeID  (write(Object.createTree(entries))); } /// ditto
		BlobID   write(immutable(ubyte)[] bytes     ) { return BlobID  (write(Object.createBlob(bytes))); } /// ditto
	}
	alias ObjectMultiWriter = RefCounted!ObjectMultiWriterImpl; /// ditto

	/// ditto
	ObjectMultiWriter createObjectWriter()
	{
		return ObjectMultiWriter(&this);
	}

	/// Batch-write the given objects to the database.
	/// The hashes are saved to the "hash" fields of the passed objects.
	void writeObjects(Git.Object[] objects)
	{
		string[] allTypes = objects.map!(obj => obj.type).toSet().keys;
		foreach (type; allTypes)
		{
			auto writer = createObjectWriter(type);
			foreach (ref obj; objects)
				if (obj.type == type)
					obj.oid = writer.write(obj.data);
		}
	}

	/// Extract a commit's tree to a given directory
	void exportCommit(string commit, string path, ObjectReader reader, bool delegate(string) pathFilter = null)
	{
		exportTree(reader.read(commit).parseCommit().tree, path, reader, pathFilter);
	}

	/// Extract a tree to a given directory
	void exportTree(TreeID treeHash, string path, ObjectReader reader, bool delegate(string) pathFilter = null)
	{
		void exportSubTree(OID treeHash, string[] subPath)
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
	TreeID importTree(string path, ObjectMultiWriter writer, bool delegate(string) pathFilter = null)
	{
		static // Error: variable ae.sys.git.Repository.importTree.writer has scoped destruction, cannot build closure
		TreeID importSubTree(string path, string subPath, ref ObjectMultiWriter writer, bool delegate(string) pathFilter)
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
			return TreeID(writer.write(Object.createTree(entries)));
		}
		return importSubTree(path, path, writer, pathFilter);
	}

	/// Spawn a update-ref process which can update git refs on the fly.
	struct RefWriterImpl
	{
		private bool initialized;
		private ProcessPipes pipes;

		/*private*/ this(ProcessPipes pipes)
		{
			this.pipes = pipes;
			initialized = true;
		}

		private void op(string op)
		{
			pipes.stdin.write(op, '\0');
			pipes.stdin.flush();
		}

		private void op(string op, bool noDeref, string refName, CommitID*[] hashes...)
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

		/// Send update-ref operations (as specified in its man page).
		void update   (string refName, CommitID newValue                   , bool noDeref = false) { op("update", noDeref, refName, &newValue, null     ); }
		void update   (string refName, CommitID newValue, CommitID oldValue, bool noDeref = false) { op("update", noDeref, refName, &newValue, &oldValue); } /// ditto
		void create   (string refName, CommitID newValue                   , bool noDeref = false) { op("create", noDeref, refName, &newValue           ); } /// ditto
		void deleteRef(string refName                                      , bool noDeref = false) { op("delete", noDeref, refName,            null     ); } /// ditto
		void deleteRef(string refName,                    CommitID oldValue, bool noDeref = false) { op("delete", noDeref, refName,            &oldValue); } /// ditto
		void verify   (string refName                                      , bool noDeref = false) { op("verify", noDeref, refName,            null     ); } /// ditto
		void verify   (string refName,                    CommitID oldValue, bool noDeref = false) { op("verify", noDeref, refName,            &oldValue); } /// ditto
		void start    (                                                                          ) { op("start"                                         ); } /// ditto
		void prepare  (                                                                          ) { op("prepare"                                       ); } /// ditto
		void commit   (                                                                          ) { op("commit"                                        ); } /// ditto
		void abort    (                                                                          ) { op("abort"                                         ); } /// ditto

		deprecated void update   (string refName, OID newValue              , bool noDeref = false) { op("update", noDeref, refName, cast(CommitID*)&newValue, null                    ); }
		deprecated void update   (string refName, OID newValue, OID oldValue, bool noDeref = false) { op("update", noDeref, refName, cast(CommitID*)&newValue, cast(CommitID*)&oldValue); }
		deprecated void create   (string refName, OID newValue              , bool noDeref = false) { op("create", noDeref, refName, cast(CommitID*)&newValue                          ); }
		deprecated void deleteRef(string refName,               OID oldValue, bool noDeref = false) { op("delete", noDeref, refName,                           cast(CommitID*)&oldValue); }
		deprecated void verify   (string refName,               OID oldValue, bool noDeref = false) { op("verify", noDeref, refName,                           cast(CommitID*)&oldValue); }

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
	alias RefWriter = RefCounted!RefWriterImpl; /// ditto

	/// ditto
	RefWriter createRefWriter()
	{
		auto pipes = this.pipe(`update-ref`, `-z`, `--stdin`);
		return RefWriter(pipes);
	}

	/// Tries to match the default destination of `git clone`.
	static string repositoryNameFromURL(string url)
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
}

deprecated alias Repository = Git;
deprecated alias History = Git.History;
deprecated alias Commit = Git.History.Commit;
deprecated alias GitObject = Git.Object;
deprecated alias Hash = Git.OID;
deprecated Git.Authorship parseAuthorship(string authorship) { return Git.Authorship(authorship); }

deprecated Git.CommitID toCommitHash(in char[] hash) { return Git.CommitID(Git.OID(hash)); }

deprecated unittest
{
	assert(toCommitHash("0123456789abcdef0123456789ABCDEF01234567").oid.sha1 == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67]);
}

deprecated string toString(ref const Git.OID oid) { return oid.toString(); }

deprecated alias repositoryNameFromURL = Git.repositoryNameFromURL;
