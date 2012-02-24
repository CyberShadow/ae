module ae.utils.meta_x;

// Based on idea from Timon Gehr.
// http://forum.dlang.org/post/jdiu5s$13bo$1@digitalmars.com

template X(string x)
{
	enum X = xImpl(x);
}

private string xImpl(string x)
{
	string r;

	for (size_t i=0; i<x.length; i++)
		if (x[i]=='@' && x[i+1]=='(')
		{
			auto j = i+2;
			for (int nest=1; nest; j++)
				nest += x[j] == '(' ? +1 : x[j] == ')' ? -1 : 0;

			r ~= `"~(` ~ x[i+2..j-1] ~ `)~"`;
			i = j-1;
		}
		else
		{
			if (x[i]=='"' || x[i]=='\\')
				r ~= "\\";
			r ~= x[i];
		}
	return `"` ~ r ~ `"`;
}

unittest
{
	enum VAR = "aoeu";
	int aoeu;

	string INSTALL_MEANING_OF_LIFE(string TARGET)
	{
		return mixin(X!q{
			@(TARGET) = 42;
		});
	}

	mixin(INSTALL_MEANING_OF_LIFE(VAR));
	assert(aoeu == 42);
}

