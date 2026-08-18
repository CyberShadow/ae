/**
 * Incremental D-Bus frame decoding.
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

module ae.net.dbus.codec;

import ae.sys.data : Data;
import ae.sys.dataset : DataVec, bytes, joinData, shift;

import ae.net.dbus.common : DbusMessage, DbusProtocolException;
import ae.net.dbus.marshal : dbusMessageLengthFromFixedHeader, decodeDbusMessage;

debug(ae_unittest)
import ae.net.dbus.common : DbusByteOrder, DbusInterfaceName, DbusMemberName,
	DbusMessageType, DbusObjectPath;
debug(ae_unittest) import ae.net.dbus.marshal : encodeDbusMessage;
debug(ae_unittest) import ae.net.dbus.value : DbusBody, DbusVariant;

/**
 * Buffers stream fragments until complete D-Bus frames are available.  The
 * value decoder copies every received semantic value, so completed frames can
 * be released before their messages are returned to the caller.
 */
package(ae.net.dbus) final class DbusFrameDecoder
{
	private DataVec buffered;
	private size_t expectedFrameLength_;

	DbusMessage[] feed(Data fragment)
	{
		DbusMessage[] result;
		feed(fragment, (DbusMessage message) {
			result ~= message;
			return true;
		});
		return result;
	}

	/**
	 * Delivers each complete frame before inspecting the next buffered frame.
	 * Returning false retains the undecoded suffix for a later call. A
	 * DbusProtocolException from parsing or the sink resets this decoder and is
	 * rethrown unchanged.
	 */
	void feed(Data fragment, scope bool delegate(DbusMessage message) sink)
	{
		assert(sink !is null);
		try
		{
			if (fragment.length)
				buffered ~= fragment.dup;

			while (true)
			{
				auto available = buffered.bytes;
				if (expectedFrameLength_ == 0)
				{
					if (available.length < 16)
						return;
					ubyte[16] fixedHeader;
					foreach (index; 0 .. fixedHeader.length)
						fixedHeader[index] = available[index];
					expectedFrameLength_ = dbusMessageLengthFromFixedHeader(fixedHeader[]);
				}

				if (available.length < expectedFrameLength_)
					return;

				{
					auto frame = available[0 .. expectedFrameLength_].joinData();
					consumeBufferedPrefix(expectedFrameLength_);
					expectedFrameLength_ = 0;
					DbusMessage message;
					frame.enter((scope bytes) {
						message = decodeDbusMessage(bytes);
					});
					if (!sink(message))
						return;
				}
			}
		}
		catch (DbusProtocolException exception)
		{
			reset();
			throw exception;
		}
	}

	private void consumeBufferedPrefix(size_t amount)
	{
		bool splitsBufferedData;
		size_t remaining = amount;
		foreach (data; buffered[])
		{
			if (remaining < data.length)
			{
				splitsBufferedData = remaining != 0;
				break;
			}
			remaining -= data.length;
			if (remaining == 0)
				break;
		}
		assert(remaining == 0 || splitsBufferedData);
		shift(buffered, amount);
		if (splitsBufferedData && buffered.length)
			buffered[0] = buffered[0].dup;
	}

	void reset()
	{
		buffered = DataVec.init;
		expectedFrameLength_ = 0;
	}

	@property size_t bufferedLength()
	{
		return buffered.bytes.length;
	}

	@property Data bufferedData()
	{
		return buffered.bytes[].joinData().dup;
	}

	@property size_t expectedFrameLength()
	{
		return expectedFrameLength_;
	}
}

debug(ae_unittest)
private Data dbusCodecTestFrame(uint serial, string member, string text)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodCall;
	message.serial = serial;
	message.headers.path = DbusObjectPath.parse("/org/example/Codec");
	message.headers.interfaceName = DbusInterfaceName.parse("org.example.Codec");
	message.headers.member = DbusMemberName.parse(member);
	message.body = DbusBody.from(text);
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private void assertDbusCodecTestMessage(const ref DbusMessage message,
	uint serial, string member, string text)
{
	assert(message.byteOrder == DbusByteOrder.littleEndian);
	assert(message.messageType == DbusMessageType.methodCall);
	assert(message.serial == serial);
	assert(message.headers.path.text == "/org/example/Codec");
	assert(message.headers.interfaceName.text == "org.example.Codec");
	assert(message.headers.member.text == member);
	assert(message.body.signature.text == "s");
	auto values = message.body.values;
	assert(values.length == 1);
	assert(values[0].get!string() == text);
}

debug(ae_unittest)
private void expectDbusCodecProtocol(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusProtocolException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private immutable ubyte[] dbusCodecLiteralContainerFrame = [
	0x6c, 0x02, 0x00, 0x01, 0x3c, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x1d, 0x00, 0x00, 0x00,
	0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x08, 0x01, 0x67, 0x00, 0x0f, 0x61, 0x79, 0x61,
	0x79, 0x79, 0x28, 0x79, 0x75, 0x29, 0x76, 0x61,
	0x7b, 0x73, 0x76, 0x7d, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
	0x01, 0x02, 0x03, 0x11, 0x00, 0x00, 0x00, 0x00,
	0x22, 0x00, 0x00, 0x00, 0x66, 0x55, 0x44, 0x33,
	0x01, 0x75, 0x00, 0x00, 0x44, 0x33, 0x22, 0x11,
	0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x04, 0x00, 0x00, 0x00, 0x64, 0x65, 0x65, 0x70,
	0x00, 0x01, 0x76, 0x00, 0x01, 0x75, 0x00, 0x00,
	0x09, 0x00, 0x00, 0x00,
];

debug(ae_unittest)
private void assertDbusCodecLiteralContainer(const ref DbusMessage message)
{
	assert(message.messageType == DbusMessageType.methodReturn);
	assert(message.headers.replySerial == 1);
	assert(message.body.signature.text == "ayayy(yu)va{sv}");
	auto values = message.body.values;
	assert(values[0].get!(ubyte[])().length == 0);
	assert(values[1].get!(ubyte[])() == [1, 2, 3]);
	assert(values[4].get!DbusVariant().get!uint() == 0x11223344);
	auto dictionary = values[5].get!(DbusVariant[string])();
	assert(dictionary["deep"].get!DbusVariant().get!uint() == 9);
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(1, "Fragmented", "fragmented body");
	auto decoder = new DbusFrameDecoder;

	auto firstInput = Data(frame.toGC[0 .. 7]);
	auto expectedFirstInput = firstInput.toGC;
	auto messages = decoder.feed(firstInput);
	firstInput[0] = cast(ubyte) 'B';
	firstInput = null;
	assert(messages.length == 0);
	assert(decoder.bufferedLength == expectedFirstInput.length);
	assert(decoder.bufferedData.toGC == expectedFirstInput);
	assert(decoder.expectedFrameLength == 0);

	auto bufferedCopy = decoder.bufferedData;
	bufferedCopy[0] = cast(ubyte) 'B';
	assert(decoder.bufferedData.toGC == expectedFirstInput);

	messages = decoder.feed(frame[7 .. 16]);
	assert(messages.length == 0);
	assert(decoder.bufferedLength == 16);
	assert(decoder.bufferedData == frame[0 .. 16]);
	assert(decoder.expectedFrameLength == frame.length);

	messages = decoder.feed(frame[16 .. frame.length - 1]);
	assert(messages.length == 0);
	assert(decoder.bufferedLength == frame.length - 1);
	assert(decoder.bufferedData == frame[0 .. frame.length - 1]);
	assert(decoder.expectedFrameLength == frame.length);

	messages = decoder.feed(frame[frame.length - 1 .. $]);
	assert(messages.length == 1);
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);

	frame = null;
	decoder.reset();
	assertDbusCodecTestMessage(messages[0], 1, "Fragmented", "fragmented body");
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(6, "EverySplit", "all split points");
	foreach (split; 0 .. frame.length + 1)
	{
		auto decoder = new DbusFrameDecoder;
		auto first = decoder.feed(frame[0 .. split]);
		if (split < frame.length)
			assert(first.length == 0);
		else
			assert(first.length == 1);
		auto second = decoder.feed(frame[split .. $]);
		if (split < frame.length)
		{
			assert(second.length == 1);
			assertDbusCodecTestMessage(second[0], 6, "EverySplit", "all split points");
		}
		else
			assert(second.length == 0);
	}
}

debug(ae_unittest) unittest
{
	assert(dbusCodecLiteralContainerFrame.length == 108);
	foreach (split; 0 .. dbusCodecLiteralContainerFrame.length + 1)
	{
		auto decoder = new DbusFrameDecoder;
		auto first = decoder.feed(Data(dbusCodecLiteralContainerFrame.dup[0 .. split]));
		if (split < dbusCodecLiteralContainerFrame.length)
			assert(first.length == 0);
		else
			assert(first.length == 1);
		auto second = decoder.feed(Data(dbusCodecLiteralContainerFrame.dup[split .. $]));
		if (split < dbusCodecLiteralContainerFrame.length)
		{
			assert(second.length == 1);
			assertDbusCodecLiteralContainer(second[0]);
		}
		else
			assert(second.length == 0);
	}
}

debug(ae_unittest) unittest
{
	auto firstFrame = dbusCodecTestFrame(2, "First", "first body");
	auto secondFrame = dbusCodecTestFrame(3, "Second", "second body");
	auto suffixFrame = dbusCodecTestFrame(4, "Suffix", "incomplete body");
	assert(suffixFrame.length > 20);
	auto input = firstFrame ~ secondFrame ~ suffixFrame[0 .. 20];
	auto decoder = new DbusFrameDecoder;

	auto messages = decoder.feed(input);
	assert(messages.length == 2);
	assert(decoder.bufferedLength == 20);
	assert(decoder.bufferedData == suffixFrame[0 .. 20]);
	assert(decoder.expectedFrameLength == suffixFrame.length);

	input[0] = cast(ubyte) 'B';
	input = null;
	assert(decoder.bufferedData == suffixFrame[0 .. 20]);
	assertDbusCodecTestMessage(messages[0], 2, "First", "first body");
	assertDbusCodecTestMessage(messages[1], 3, "Second", "second body");
	auto completed = decoder.feed(suffixFrame[20 .. $]);
	assert(completed.length == 1);
	assertDbusCodecTestMessage(completed[0], 4, "Suffix", "incomplete body");
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(9, "BeforeInvalid", "first delivery");
	immutable ubyte[] invalidFixedHeader = [cast(ubyte) 'x', 1, 0, 1,
		0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0];
	auto decoder = new DbusFrameDecoder;
	size_t deliveries;
	DbusProtocolException caught;
	try
		decoder.feed(frame ~ Data(invalidFixedHeader.dup), (DbusMessage message) {
			deliveries++;
			assertDbusCodecTestMessage(message, 9, "BeforeInvalid", "first delivery");
			return true;
		});
	catch (DbusProtocolException exception)
		caught = exception;
	assert(deliveries == 1);
	assert(caught !is null);
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);
	auto fresh = decoder.feed(frame);
	assert(fresh.length == 1);
	assertDbusCodecTestMessage(fresh[0], 9, "BeforeInvalid", "first delivery");
}

debug(ae_unittest) unittest
{
	auto first = dbusCodecTestFrame(10, "StopFirst", "first frame");
	auto second = dbusCodecTestFrame(11, "StopSecond", "second frame");
	auto decoder = new DbusFrameDecoder;
	size_t deliveries;
	decoder.feed(first ~ second, (DbusMessage message) {
		deliveries++;
		assertDbusCodecTestMessage(message, 10, "StopFirst", "first frame");
		return false;
	});
	assert(deliveries == 1);
	assert(decoder.bufferedData == second);
	auto remaining = decoder.feed(Data.init);
	assert(remaining.length == 1);
	assertDbusCodecTestMessage(remaining[0], 11, "StopSecond", "second frame");
	assert(decoder.bufferedLength == 0);
	assert(decoder.expectedFrameLength == 0);
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(12, "SinkFailure", "reset state");
	auto decoder = new DbusFrameDecoder;
	auto cause = new DbusProtocolException("sink protocol failure");
	DbusProtocolException caught;
	scope bool delegate(DbusMessage) sink = (DbusMessage) {
		throw cause;
	};
	try
		decoder.feed(frame, sink);
	catch (DbusProtocolException exception)
		caught = exception;
	assert(caught is cause);
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);
	auto fresh = decoder.feed(frame);
	assert(fresh.length == 1);
	assertDbusCodecTestMessage(fresh[0], 12, "SinkFailure", "reset state");
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(5, "Reset", "discard this partial frame");
	auto decoder = new DbusFrameDecoder;

	auto messages = decoder.feed(frame[0 .. 16]);
	assert(messages.length == 0);
	assert(decoder.bufferedLength == 16);
	assert(decoder.expectedFrameLength == frame.length);

	decoder.reset();
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);

	messages = decoder.feed(frame);
	assert(messages.length == 1);
	assertDbusCodecTestMessage(messages[0], 5, "Reset", "discard this partial frame");
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(7, "AfterError", "fresh state");
	immutable ubyte[][5] malformed = [
		[cast(ubyte) 'x', 1, 0, 1, 0, 0, 0, 0,
			1, 0, 0, 0, 0, 0, 0, 0],
		[cast(ubyte) 'l', 0, 0, 1, 0, 0, 0, 0,
			1, 0, 0, 0, 0, 0, 0, 0],
		[cast(ubyte) 'l', 1, 0, 2, 0, 0, 0, 0,
			1, 0, 0, 0, 0, 0, 0, 0],
		[cast(ubyte) 'l', 1, 0, 1, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0],
		[cast(ubyte) 'l', 1, 0, 1, 0xff, 0xff, 0xff, 0xff,
			1, 0, 0, 0, 0, 0, 0, 0],
	];
	foreach (fixedHeader; malformed)
	{
		auto decoder = new DbusFrameDecoder;
		expectDbusCodecProtocol({ decoder.feed(Data(fixedHeader.dup)); });
		assert(decoder.bufferedLength == 0);
		assert(decoder.bufferedData.length == 0);
		assert(decoder.expectedFrameLength == 0);
		auto messages = decoder.feed(frame);
		assert(messages.length == 1);
		assertDbusCodecTestMessage(messages[0], 7, "AfterError", "fresh state");
	}
}

debug(ae_unittest) unittest
{
	auto frame = dbusCodecTestFrame(8, "ResetStates", "discard every partial state");
	foreach (split; [cast(size_t) 1, 16, 45, frame.length - 1])
	{
		auto decoder = new DbusFrameDecoder;
		auto messages = decoder.feed(frame[0 .. split]);
		assert(messages.length == 0);
		decoder.reset();
		assert(decoder.bufferedLength == 0);
		assert(decoder.bufferedData.length == 0);
		assert(decoder.expectedFrameLength == 0);
		messages = decoder.feed(frame);
		assert(messages.length == 1);
		assertDbusCodecTestMessage(messages[0], 8, "ResetStates",
			"discard every partial state");
	}
}

debug(ae_unittest) unittest
{
	auto suffix = dbusCodecLiteralContainerFrame[0 .. 7].dup;
	auto inputBytes = dbusCodecLiteralContainerFrame ~ suffix;
	auto decoder = new DbusFrameDecoder;
	auto input = Data(inputBytes);
	auto messages = decoder.feed(input);
	input = null;

	assert(messages.length == 1);
	assertDbusCodecLiteralContainer(messages[0]);
	assert(decoder.bufferedLength == suffix.length);
	assert(decoder.expectedFrameLength == 0);
	{
		auto retained = decoder.bufferedData;
		assert(retained.toGC == suffix);
	}
	auto completed = decoder.feed(Data(dbusCodecLiteralContainerFrame[suffix.length .. $]));
	assert(completed.length == 1);
	assertDbusCodecLiteralContainer(completed[0]);
	decoder.reset();
	assert(decoder.bufferedLength == 0);
	assert(decoder.bufferedData.length == 0);
	assert(decoder.expectedFrameLength == 0);
}

debug(ae_unittest) unittest
{
	immutable ubyte[] suffix = [cast(ubyte) 'l', 1, 0, 1, 0, 0, 0];
	auto decoder = new DbusFrameDecoder;
	auto original = Data(dbusCodecLiteralContainerFrame ~ suffix);
	size_t originalTailAddress;
	original.enter((scope bytes) {
		originalTailAddress = cast(size_t) bytes.ptr + dbusCodecLiteralContainerFrame.length;
	});
	decoder.buffered ~= original;
	decoder.consumeBufferedPrefix(dbusCodecLiteralContainerFrame.length);
	assert(decoder.bufferedLength == suffix.length);
	assert(decoder.buffered.length == 1);
	size_t retainedAddress;
	decoder.buffered[0].enter((scope bytes) {
		retainedAddress = cast(size_t) bytes.ptr;
		assert(bytes == suffix);
	});
	assert(retainedAddress != originalTailAddress);
	original = null;
	decoder.buffered[0].enter((scope bytes) {
		assert(bytes == suffix);
	});
	decoder.reset();
	assert(decoder.bufferedLength == 0);
}

debug(ae_unittest) unittest
{
	immutable ubyte[] suffix = [cast(ubyte) 'l', 1, 0, 1, 0, 0, 0];
	auto decoder = new DbusFrameDecoder;
	auto complete = Data(dbusCodecLiteralContainerFrame);
	auto separateSuffix = Data(suffix);
	size_t separateSuffixAddress;
	separateSuffix.enter((scope bytes) {
		separateSuffixAddress = cast(size_t) bytes.ptr;
	});
	decoder.buffered ~= complete;
	decoder.buffered ~= separateSuffix;
	decoder.consumeBufferedPrefix(dbusCodecLiteralContainerFrame.length);
	assert(decoder.buffered.length == 1);
	assert(decoder.bufferedLength == suffix.length);
	decoder.buffered[0].enter((scope bytes) {
		assert(cast(size_t) bytes.ptr == separateSuffixAddress);
		assert(bytes == suffix);
	});
	complete = null;
	separateSuffix = null;
	decoder.reset();
	assert(decoder.bufferedLength == 0);
}
