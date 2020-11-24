ae.utils.sd
===========

This package implements components which allow building **structured data processing pipelines**.
This includes things such as parsing and emitting JSON / XML / etc., serializing and deserializing D types (including structs and arrays), and filtering / conversion operations on structured data.

As the common protocol used by these components is not explicitly defined anywhere in the code, it is described here instead.

Overview
--------

Components in this package are combined into a pipeline, not unlike a D range chain. Unlike a D range chain, chain components expose an API and calls travel both up and down the chain as the hierarchy of the structured data being processed is descended into.

The overall flow is as follows:

- The sink calls `source.read(handler)`, where `handler` is an object that the sink constructed defining which kinds of objects it can handle in the given context.
- The source determines which kinds of objects the sink can accept, by checking which methods are defined in `handler`, reads relevant data, and calls the appropriate `handler.handleXXX` method. It also provides a reader object which can be used by the sink for further recursive reads from this source.
- The sink's `handleXXX` implementation processes the received data.
- If applicable, the sink's handler then recurses using the provided source reader object. It can customize the behavior by providing different types of handler objects when recursing depending on the received data, e.g. to deserialize different types depending on a struct's field name.

API
---

Components thus interact with each other using objects implementing the following API:

- **Reader** objects are provided by sources, and implement a `.read(Handler)(Handler handler)` method. This method indicates a request to fetch a value and send it to the provided handler. `read` calls thus travel up the processing chain, from sinks to sources.
- **Handler** objects provide sources a way to send values to sinks. They implement various `handleXXX` methods, which may accept a new reader object for reading nested data. `handleXXX` calls thus travel down the processing chain, from sources to sinks.

Contexts
--------

The sink specifies what kind of objects it accepts from the source, and provides the API to process them, using handler objects.

Handler objects are non-specific types (classes / structs / struct pointers) which have one or more `handleXXX` methods, where `XXX` is the kind of value to be processed (scalar, array, struct...). Existence of a `handleXXX` method indicates that the sink is ready to accept an `XXX` kind of value in the given circumstance. If only one `handleXXX` method is defined, then the sink expects only a value of that kind in that circumstance.

Some `handleXXX` methods may be templated using a type (such as when the source wants to provide a complete value of that type); in this case, there should also be an enum template `canHandleXXX`, which evaluates to `true` if the source should try instantiating `handleXXX!T`. (The rationale for this is that the alternative is to check if `handleXXX!T` instantiation succeeds, which makes debugging difficult due to error gagging.)

Aside from sink-specified preferences, different kinds of values introduce special contexts for reading different parts of a special types, e.g. for `struct` fields.

#### Top-level context

The top-level context is used to define handling for different kinds of values. All methods are optional. Exactly one method will be called exactly once; if no methods match the source data, an error is raised.

- `handleValue!T`
  - represents a raw value of type `T` (if the source can provide one and the sink can accept it)
  - can be a basic type, such as `char` or `bool`, or a complex type such as a `struct` or an array
  - the argument is a value of type `T`
  - `canHandleValue` must be defined and `canHandleValue!T` must be `true`
  - if present and enabled for `T`, takes precedence over other methods
  - terminal (no reader / child context)
- `handleTypeHint!T`
  - indicates to the sink that the source knows exactly the full structure of the following value
  - represents a promise to deliver a value according to the structure described by `T`
  - `T` is a D representation of the type, with straight-forward rules:
    - basic types indicate themselves, and represent a promise to call `handleValue`
    - arrays represent a promise to call `handleArray`
    - associative arrays represent a promise to call `handleMap`
    - if `handleValue!U` is present (where `U` is `T` or any subtype of `T`), it can be used if present, as usual
  - `canHandleTypeHint` must be defined and `canHandleTypeHint!T` must be `true`
  - if present and enabled for `T`, takes precedence over other methods below
  - -> [Top-level context](#top-level-context)
    - the next context should be able to handle `T` accordingly (piecemeal using `handleArray` / `handleMap` etc., or optionally also in whole using `handleValue!T`)
    - the next context should not have `handleTypeHint!T` again for this `T`, as that may result in infinite recursion
- `handleNumeric`
  - represents a text string representing a number of unspecified size or precision, as it appears in the input (generally something that can be converted with `std.conv.to`)
  - optional
  - TODO, probably should be defined more explicitly - in any case, JSON/YAML syntax or a superset thereof
  - -> [Array context](#array-context)
- `handleArray`
  - represents an array of non-specific values
  - optional
  - -> [Array context](#array-context)
- `handleMap`
  - represents a list of ordered pairs
  - optional
  - keys are generally expected to be unique
  - -> [Map context](#map-context)

Here is how some basic common types are communicated:

- **strings**: You may notice that there is no `handleString`; strings are instead represented as arrays of characters. `handleSlice` is used to batch-process string spans (segmented by escape sequences and input buffer chunk boundaries) for efficiency. Because e.g. JSON has different syntax for strings than from other kinds of arrays, `handleTypeHint!T` is used to allow sources to announce beforehand that the written array will consist of characters, and thus emit a string literal instead of an array literal.
- **numbers** are represented as their basic D type (`int` / `double`) if their binary size is known, or `handleNumeric` otherwise.
- `true` / `false`: represented as `handleValue!bool`.
- `null`: represented as `handleValue!(typeof(null))` `typeof(null)` is a distinct type in D with a single value (`null`).

#### Array context

- `handleSlice!T`
  - represents several array elements of type `T`
  - `canHandleSlice` must be defined and `canHandleSlice!T` must be `true`
  - if present and enabled for `T`, takes precedence over individual `handleElement` calls
- `handleElement`
  - represents one array element
  - required, called zero or more times
  - -> [Top-level context](#top-level-context)
- `handleEnd`
  - represents the end of the array
  - required, called exactly once
  - terminal (no reader / child context)

#### Map context

- `handlePair`
  - begin a new map pair
  - required, called zero or more times
  - -> [Map pair context](#map-pair-context)
- `handleEnd`
  - represents the end of the map
  - required, called exactly once
  - terminal (no reader / child context)

#### Map pair context

- `handlePairKey`
  - the pair key
  - required, called exactly once
  - -> [Top-level context](#top-level-context)
- `handlePairValue`
  - the pair value
  - required, called exactly once
  - -> [Top-level context](#top-level-context)
- `handleEnd`
  - represents the end of the pair
  - required, called exactly once
  - terminal (no reader / child context)
