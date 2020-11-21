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

The top-level context is used to define handling for different kinds of values.

- `handleValue!T`
  - represents a raw value of type `T` (if the source can provide one and the sink can accept it)
  - the argument is a value of type `T`
  - `canHandleValue` must be defined and `canHandleValue!T` must be `true`
  - if present and enabled for `T`, takes precedence over other methods
  - terminal (no reader / child context)
- `handleNull`
  - represents the "null" token (such as JSON `null`)
  - no arguments
  - terminal (no reader / child context)
- `handleNumeric`
  - represents a text string representing a number of unspecified size or precision, as it appears in the input
  - -> [Array context](#array-context)
- `handleArrayOf!T` 
  - represents an array of raw values of type `T` (if the source can provide them and the sink can accept them)
  - `canHandleArrayOf` must be defined and `canHandleArrayOf!T` must be `true`
  - if present and enabled for `T`, takes precedence over `handleArray`
  - otherwise, has the same arguments and behaves the same as `handleArray`
- `handleArray`
  - represents an array of non-specific values
  - -> [Array context](#array-context)
- `handleMap`
  - represents a list of ordered pairs
  - keys are generally expected to be unique
  - -> [Map context](#map-context)

You may notice that there is no `handleString`; strings are instead represented as arrays of characters. `handleSlice` is used to batch-process string spans (segmented by escape sequences and input buffer chunk boundaries) for efficiency. Because e.g. JSON has different syntax for strings than from other kinds of arrays, `handleArrayOf!T` exists to allow sources to announce beforehand that the written array will consist of characters.

#### Array context

- `handleSlice!T`
  - represents several array elements of type `T`
  - `canHandleSlice` must be defined and `canHandleSlice!T` must be `true`
  - if present and enabled for `T`, takes precedence over individual `handleElement` calls
- `handleElement`
  - represents one array element
  - -> [Top-level context](#top-level-context)
- `handleEnd`
  - represents the end of the array
  - always called
  - terminal (no reader / child context)

#### Map context

- `handlePair`
  - begin a new map pair
  - -> [Map pair context](#map-pair-context)
- `handleEnd`
  - represents the end of the map
  - always called
  - terminal (no reader / child context)

#### Pair context

- `handleKey`
  - the pair key
  - -> [Top-level context](#top-level-context)
- `handleValue`
  - the pair value
  - -> [Top-level context](#top-level-context)
