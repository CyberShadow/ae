[![Travis](https://travis-ci.org/CyberShadow/ae.svg?branch=master)](https://travis-ci.org/CyberShadow/ae) [![AppVeyor](https://ci.appveyor.com/api/projects/status/5stp93xj578fdwwc?svg=true)](https://ci.appveyor.com/project/CyberShadow/ae)

About this library
==================

*ae* (fully named *ArmageddonEngine*) was initially intended to be the open-source part of an ambitious D rewrite of the 1999 video game "Worms Armageddon", of which I am a [maintainer](http://worms2d.info/CyberShadow).
As the library accumulated code and found use in various projects, its original purpose diminished.
In the future, if there is sufficient reason for it (e.g. to allow static linking), it may be split up into multiple libraries.

License
=======

*Most* of this library is licensed under the [Mozilla Public License, v. 2.0](http://mozilla.org/MPL/2.0/).

Modules under licenses other than MPL are:

- `ae.utils.digest_murmurhash3` - D port of a C MurmurHash3 implementation. **Public Domain**.
- `ae.utils.graphics.fonts.font8x8` - Data for an 8x8 bitmap font created by Daniel Hepper. **Public Domain**.
- `ae.utils.graphics.hls` - Code to convert between RGB and HLS. Ported from a Microsoft Knowledge Base article. **License [unclear](https://opensource.stackexchange.com/questions/4779/is-it-legal-to-use-code-from-microsoft-knowledge-base-article-in-an-open-source)**.
- `ae.utils.text.parsefp` - Parse floating-point values from strings. Adapted from Phobos. **[Boost License 1.0](https://www.boost.org/LICENSE_1_0.txt)**.

Using this library
==================

For a complete-newbie Windows tutorial of setting up *ae* and building an SDL game demo, see [here](http://worms2d.info/4/Development_setup).

This library is not meant to be compiled as a static (.lib, .a) or shared (.dll, .so) library.
Do not attempt to do so; you will run into problems with multiple entry points, dependencies you may not need, and other problems.
Instead, it is intended to be used as a source library, together with a dependency-discovering build tool (e.g. [rdmd](http://dlang.org/rdmd.html)).

The recommended way to use the library is to set it up as a git external in your project's root, as seen [here](https://github.com/CyberShadow/ForumAntiSpam).
This will link your project with a specific commit of the library, to avoid breakage due to API changes (see below).

Dub is also supported, with the library being split up into subpackages according to the necessary external dependencies.
See `dub.sdl` for details.

Overview
========

The library is split into the following packages:

 * `ae.demo` – This package contains a few demos for various parts of the library. Most of these are SDL demos.
 * `ae.net` – All the networking code (HTTP, NNTP, IRC) lives here.
 * `ae.sys` – Utility code which primarily interfaces with other systems (including the operating system).
 * `ae.ui` – Framework for creating 2D games and graphical applications (SDL, OpenGL).
 * `ae.utils` – Utility code which primarily manipulates data.

Notable sub-packages:

 * `ae.sys.d` – Builds arbitrary versions of D. Shared by Digger, DAutoTest, and TrenD.
 * `ae.sys.net` – High-level synchronous API for accessing network resources (URLs). Includes implementations based on cURL, WinINet, and `ae.net`.
 * `ae.utils.graphics` – Contains a templated graphical context optimized for speed, and basic support for a few image formats.
 * `ae.utils.time` – Supplements `core.time` and `std.datetime` with extras such as PHP-like parsing / formatting and floating-point duration operations.

Data
----

Many modules that handle raw data (from the network / disk) do so using the `Data` structure, defined in `ae.sys.data`.
See the module documentation for a description of the type; the quick version is that it is a type equivalent to `void[]`, with a few benefits.
Some modules use an array of `Data`, to minimize copying / reallocations when handling byte streams with unknown length.

Networking
----------

*ae* uses asynchronous event-based networking.
A `select`-based event loop dispatches events to connection objects, which then propagate them to higher-level code as necessary.
`libev` support is also available.

UI
--

Not much here yet.
There is a working game demo in `ae.demo.pewpew`.

Versioning
==========

Currently, there are no stable/development branches, and versioning is done only according to the number of commits in `master`.
Breaking changes are prefixed with `[BREAKING]` in the commit message.
Tags are created regularly for the benefit of Dub packages (e.g. [Digger](https://github.com/CyberShadow/Digger/blob/master/dub.sdl)).
