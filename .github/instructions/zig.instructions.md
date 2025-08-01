# Zig Programming Copilot Instructions

## Basic Principles
- Use English for all code and documentation.
- Explicitly declare types for variables and functions.
- Create necessary types and structs.
- Provide comprehensive documentation (docstrings/comments) for public types and functions.
- Avoid blank lines within functions.
- Prioritize explicitness: avoid hidden control flow, implicit memory allocations, and preprocessor macros.
- Treat errors as values that must be explicitly handled.
- Design for robustness, optimality, and reusability.
- Ensure source files use UTF-8 encoding.
- Avoid magic numbers; define constants.

## Naming Conventions
- TitleCase for types (structs, unions, enums, error sets) and for functions that return types.
- camelCase for other callable entities (functions and methods that do not return types).
- snake_case for variables, fields, and constants.
- Error names should always be TitleCase.
- File naming: Use TitleCase for files that implicitly represent structs with top-level fields; use snake_case otherwise.

## Functions
- Start functions with a verb.
- Use verbs for boolean variables (e.g., isLoading, hasError).
- Use complete words, not abbreviations, except for standard or well-known cases (API, URL, i, j, k, err, ctx, req, res).
- Follow established conventions (e.g., ENOENT) if they exist.
- Functions requiring memory allocation must accept an allocator as an argument (allocator-passing style).
- Functions that can fail should return "error unions" (!T).
- Use try to propagate errors up the call stack.
- Use catch to handle errors locally by providing a default value or alternative behavior.
- Employ if/else and switch statements for more detailed error recovery logic.
- Use the defer keyword to guarantee that cleanup operations (e.g., freeing memory, closing files) are executed when the current scope exits.
- Add contextual information to errors using std.debug.print or by defining custom ErrorContext structs.
- Write short, single-purpose functions.
- Maintain a single level of abstraction.

## Data
- Prefer composite types over primitive types.
- Explicitly manage memory using Zig's allocator system.

## Structs (Classes)
- Follow SOLID principles.
- Prefer composition over inheritance.
- Write small, single-purpose structs.
- Types (struct, union, enum, error) should be named using TitleCase.

## Error Handling
- Errors are treated as values, not exceptions, ensuring explicit handling.
- Define clear error sets to list possible error conditions a function can produce.
- Functions that can fail return "error unions" (!T), which must be explicitly unwrapped.
- Use try to propagate errors up the call stack.
- Use catch to handle errors locally, providing default values or alternative behavior.
- Utilize if/else and switch statements for comprehensive error recovery logic.
- Add contextual information to errors for improved debugging, typically using std.debug.print or custom ErrorContext structs.
- Be specific with error types by creating distinct error sets for different modules or functionalities.
- Leverage compile-time checks to catch potential errors early.

## Memory Management
- Employ explicit manual memory management through allocators (e.g., std.heap.GeneralPurposeAllocator, ArenaAllocator).
- Adhere to the "allocator-passing style," where functions requiring memory accept an allocator as an argument.
- Use the defer keyword to guarantee resource cleanup (e.g., freeing allocated memory, closing file handles) when the current scope exits.
- Handle out-of-memory conditions gracefully by using try for allocations.
- Consider implementing custom allocators for performance-critical applications.
- Utilize std.testing.allocator in tests to detect memory leaks and double-frees.

## Testing
- Write unit tests directly within test blocks embedded in source code.
- Execute tests using the zig test command.
- Use std.testing.expect for writing assertions within tests.
- test blocks are automatically ignored during normal compilation, ensuring no runtime overhead.
- Use Arrange-Act-Assert convention.
- Name test variables clearly (e.g., inputX, mockX, actualX, expectedX).

## Project Structure
- Use zig init-exe or zig init-lib to initialize a basic project with a src/ directory.
- Organize code into logical subdirectories under src/ and use the @import directive to bring in modules.
- Manage project build logic using the build.zig script at the project root.
- For external dependencies, especially local ones, use the build.zig.zon manifest file with the .path field.
- Resolve dependencies declared in build.zig.zon using b.dependency in build.zig.
- Use namespaces for logical organization (e.g., std).

## Standard Library
- Prefer the Zig Standard Library (std) for common algorithms, data structures, and utilities.
- Utilize key data structures such as ArrayList, HashMap, BitSet, DoublyLinkedList, MultiArrayList, RingBuffer, and PriorityQueue.
- Leverage modules and namespaces like Io, ascii, atomic, base64, crypto, debug, fmt, fs, heap, http, json, log, math, mem, net, os, process, simd, sort, testing, time, unicode, wasm, zip, and zon.

## Concurrency
- Use async/await syntax for writing asynchronous code, enabling non-blocking I/O and CPU-bound tasks.
- Employ channels, based on the Communicating Sequential Processes (CSP) model, for safe and efficient inter-thread communication.
- Utilize the select statement to wait for multiple channel operations simultaneously, facilitating non-blocking communication patterns.
- For low-level threading control, use primitives such as std.Thread, std.Mutex, std.Semaphore, and std.WaitGroup.
- Avoid data races and ensure thread safety by correctly applying synchronization mechanisms like mutex.lock() and defer mutex.unlock(), or semaphore.wait() and semaphore.post().
