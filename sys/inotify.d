/**
 * ae.sys.inotify
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

module ae.sys.inotify;

version(linux):

import core.sys.posix.unistd;
import core.sys.linux.sys.inotify;

import std.exception;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.utils.meta : singleton;

struct INotify
{
	/// http://man7.org/linux/man-pages/man7/inotify.7.html
	enum Mask : uint32_t
	{
		access        = IN_ACCESS       ,
		modify        = IN_MODIFY       ,
		attrib        = IN_ATTRIB       ,
		closeWrite    = IN_CLOSE_WRITE  ,
		closeNoWrite  = IN_CLOSE_NOWRITE,
		open          = IN_OPEN         ,
		movedFrom     = IN_MOVED_FROM   ,
		movedTo       = IN_MOVED_TO     ,
		create        = IN_CREATE       ,
		remove        = IN_DELETE       ,
		removeSelf    = IN_DELETE_SELF  ,
		moveSelf      = IN_MOVE_SELF    ,

		unmount       = IN_UMOUNT       ,
		qOverflow     = IN_Q_OVERFLOW   ,
		ignored       = IN_IGNORED      ,
		close         = IN_CLOSE        ,
		move          = IN_MOVE         ,
		onlyDir       = IN_ONLYDIR      ,
		dontFollow    = IN_DONT_FOLLOW  ,
		exclUnlink    = IN_EXCL_UNLINK  ,
		maskAdd       = IN_MASK_ADD     ,
		isDir         = IN_ISDIR        ,
		oneShot       = IN_ONESHOT      ,
		allEvents     = IN_ALL_EVENTS   ,
	}

	static struct WatchDescriptor { int wd; }

	alias INotifyHandler = void delegate(in char[] name, Mask mask, uint cookie);

	WatchDescriptor add(string path, Mask mask, INotifyHandler handler)
	{
		if (fd < 0)
			start();
		auto wd = inotify_add_watch(fd, path.toStringz(), mask);
		errnoEnforce(wd >= 0, "inotify_add_watch");
		handlers[wd] = handler;
		return WatchDescriptor(wd);
	}

	void remove(WatchDescriptor wd)
	{
		auto result = inotify_rm_watch(fd, wd.wd);
		errnoEnforce(result >= 0, "inotify_rm_watch");
		handlers.remove(wd.wd);
		if (!handlers.length)
			stop();
	}

private:
	int fd = -1;
	FileConnection conn;

	INotifyHandler[int] handlers;

	void start()
	{
		assert(fd < 0, "Already started");
		fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
		errnoEnforce(fd >= 0, "inotify_init1");

		conn = new FileConnection(fd);
		//conn.daemon = true;
		conn.handleReadData = &onReadData;
	}

	void stop()
	{
		assert(fd >= 0, "Not started");
		conn.disconnect();
		fd = -1;
	}

	void onReadData(Data data)
	{
		while (data.length)
		{
			enforce(data.length >= inotify_event.sizeof, "Insufficient bytes for inotify_event");
			auto pheader = cast(inotify_event*)data.contents.ptr;
			auto end = inotify_event.sizeof + pheader.len;
			enforce(data.length >= end, "Insufficient bytes for inotify name");
			auto name = cast(char[])data.contents[inotify_event.sizeof .. end];

			auto p = name.indexOf('\0');
			if (p >= 0)
				name = name[0..p];

			auto phandler = pheader.wd in handlers;
			enforce(phandler, "Unregistered inotify watch descriptor");
			(*phandler)(name, cast(Mask)pheader.mask, pheader.cookie);
			data = data[end..$];
		}
	}
}

INotify iNotify;

unittest
{
	import std.file, ae.sys.file;

	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	INotify.Mask[] events;
	INotify.WatchDescriptor wd;
	wd = iNotify.add("tmp", INotify.Mask.create | INotify.Mask.remove,
		(in char[] name, INotify.Mask mask, uint cookie)
		{
			assert(name == "killme");
			events ~= mask;
			if (events.length == 2)
				iNotify.remove(wd);
		}
	);
    touch("tmp/killme");
    remove("tmp/killme");
    socketManager.loop();

    assert(events == [INotify.Mask.create, INotify.Mask.remove]);
}
