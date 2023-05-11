[![test](https://github.com/CyberShadow/ae/actions/workflows/test.yml/badge.svg)](https://github.com/CyberShadow/ae/actions/workflows/test.yml)

About this library
==================

*ae* (***a**lmost **e**verything*) is an auxiliary general-purpose D library.  Its design goals are composability and simplicity.

Among many things, it implements an asynchronous event loop, and several network protocols, such as HTTP / IRC / TLS.

Overview
========

The library is split into the following packages:

 * `ae.demo` – This package contains a few demos for various parts of the library.
 * `ae.net` – All the networking code (event loop, HTTP, NNTP, IRC) lives here.
 * `ae.sys` – Utility code which primarily interfaces with other systems (including the operating system).
 * `ae.ui` – Framework for creating 2D games and graphical applications (SDL, OpenGL).
 * `ae.utils` – Utility code which primarily manipulates data.

Notable sub-packages:

 * `ae.sys.d` – Builds arbitrary versions of D. Shared by Digger, DAutoTest, and TrenD.
 * `ae.sys.net` – High-level synchronous API for accessing network resources (URLs). Includes implementations based on cURL, WinINet, and `ae.net`.
 * `ae.utils.functor` – Functor primitives and functions, allowing `@nogc` range manipulation and text formatting.
 * `ae.utils.graphics` – Contains a templated graphical context optimized for speed, and basic support for a few image formats.
 * `ae.utils.promise` – Implementation of Promises/A+, `async`/`await`, and related operations. Can be used on top of the `ae.net` asynchronous API.
 * `ae.utils.time` – Supplements `core.time` and `std.datetime` with extras such as PHP-like parsing / formatting and floating-point duration operations.

General concepts:

- **Data**: Many modules that handle raw data (from the network / disk) do so using the `Data` structure, defined in `ae.sys.data`.
  See the module documentation for a description of the type; the quick version is that it is a type equivalent to `void[]`, with a few benefits.
  Some modules use `DataVec`, a `Data` vector with deterministic lifetime, to minimize copying / reallocations when handling byte streams with unknown length.

- **Networking**: *ae* uses asynchronous event-based networking.
  A `select`-based event loop dispatches events to connection objects, which then propagate them to higher-level code as necessary.
  `libev` support is also available.

- **UI**: The `ae.ui` package contains basic support for cross-platform interactive applications using SDL.
  There is a working game demo in `ae.demo.pewpew`.

What uses this library?
=======================

- [DFeed](https://github.com/CyberShadow/DFeed) (forum.dlang.org) - networking, SQLite
- [Digger](https://github.com/CyberShadow/Digger) - `ae.sys.d`
- [DAutoTest](https://github.com/CyberShadow/DAutoTest) - `ae.sys.d`, web server
- [btdu](https://github.com/CyberShadow/btdu) - utility functions, duration parsing, functors
- [monocre](https://github.com/CyberShadow/monocre) - image processing
- Community WormNET services for Worms Armageddon ([web snooper](https://snoop.wormnet.net/), community server, [HostingBuddy](https://worms2d.info/HostingBuddy))
- Most of [my D projects](https://github.com/CyberShadow?language=d&tab=repositories&type=source)
- [Find more uses on GitHub](https://github.com/search?l=D&q=%22import+ae%22&type=Code)

Documentation
=============

You may peruse the documentation generated from DDoc on [ae.dpldocs.info](https://ae.dpldocs.info/).

Other ways to get started with this library is to:

- Play with the demo programs (in the `demo` directory)
- Look at open-source projects using this library (see above)
- Use your editor's "go to definition" feature to navigate the implementation.

Using this library
==================

- If you are using Dub, simply add a dependency to `ae` (or a subpackage) in your project.

  The main package has no additional dependencies, with the rest of the library being split out into sub-packages which have additional dependencies (such as OpenSSL).

  See `dub.sdl` for details.

- If you are not using Dub, note that this library has multiple entry points and many optional dependencies, so compiling and linking all `*.d` files into a single library will not work.
  In this circumstance, the best way is to simply use recursive compilation (`rdmd` or `dmd -i`).

  You can achieve strong versioning and avoid configuring compiler import paths by setting it up as a git submodule in your project's root, as seen [here](https://github.com/CyberShadow/ForumAntiSpam).

Versioning
==========

There are currently no stable/development branches, and versioning is done only according to the number of commits in `master`.

Breaking changes are prefixed with `[BREAKING]` in the commit message. 
Each such commit includes a rationale and instructions for updating affected code.

Tags are created regularly for the benefit of Dub packages (e.g. [Digger](https://github.com/CyberShadow/Digger/blob/master/dub.sdl)).

The bleeding-edge version can be found in the `next` branch (which may be regularly force-pushed).

License
=======

Except where stated otherwise, this library is licensed under the [Mozilla Public License, v. 2.0](http://mozilla.org/MPL/2.0/).
(Approximate summary: you only need to publish the source code of the files from this library that you edited.)

Modules under licenses other than MPL are:

- `ae.utils.digest_murmurhash3` - D port of a C MurmurHash3 implementation. **Public Domain**.
- `ae.utils.graphics.fonts.font8x8` - Data for an 8x8 bitmap font created by Daniel Hepper. **Public Domain**.
- `ae.utils.graphics.hls` - Code to convert between RGB and HLS. Ported from a Microsoft Knowledge Base article. **License [unclear](https://opensource.stackexchange.com/questions/4779/is-it-legal-to-use-code-from-microsoft-knowledge-base-article-in-an-open-source)**.
- `ae.utils.text.parsefp` - Parse floating-point values from strings. Adapted from Phobos. **[Boost License 1.0](https://www.boost.org/LICENSE_1_0.txt)**.
