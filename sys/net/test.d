import std.file;

static import ae.sys.net.ae;
static import ae.sys.net.curl;
version(Windows)
static import ae.sys.net.wininet;

debug static import std.stdio;

void test(string moduleName, string className)()
{
	debug std.stdio.stderr.writeln("Testing " ~ className);

	mixin("import ae.sys.net." ~ moduleName ~ ";");
	mixin("alias Net = " ~ className ~ ";");
	auto net = new Net();

	debug std.stdio.stderr.writeln(" - getFile");
	{
		assert(net.getFile("http://net.d-lang.appspot.com/testUrl1") == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - downloadFile");
	{
		enum fn = "test.txt";
		if (fn.exists) fn.remove();
		scope(exit) if (fn.exists) fn.remove();

		net.downloadFile("http://net.d-lang.appspot.com/testUrl1", fn);
		assert(fn.readText() == "Hello world\n");
	}
}

unittest
{
	test!("ae", "AENetwork");
	test!("curl", "CurlNetwork");
	version(Windows)
	test!("wininet", "WinInet");
}
