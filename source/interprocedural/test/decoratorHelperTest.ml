(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Core
open Pyre
open Analysis
open Ast
open Interprocedural
open Test

let setup ?(additional_sources = []) ~context ~handle source =
  let project =
    let additional_sources =
      List.map additional_sources ~f:(fun { handle; source } -> handle, source)
    in
    ScratchProject.setup ~context ~external_sources:[] ([handle, source] @ additional_sources)
  in
  let { ScratchProject.BuiltTypeEnvironment.sources; type_environment; _ } =
    ScratchProject.build_type_environment project
  in
  let source =
    List.find_exn sources ~f:(fun { Source.source_path = { SourcePath.relative; _ }; _ } ->
        String.equal relative handle)
  in
  source, TypeEnvironment.read_only type_environment


let test_all_decorators context =
  let assert_decorators source expected =
    let _, environment = setup ~context ~handle:"test.py" source in
    assert_equal
      ~cmp:[%equal: Reference.t list]
      ~printer:[%show: Reference.t list]
      expected
      (DecoratorHelper.all_decorators environment |> List.sort ~compare:[%compare: Reference.t])
  in
  assert_decorators
    {|
    @decorator1
    def foo(z: str) -> None:
      print(z)

    @decorator2
    @decorator3(1, 2)
    def bar(z: str) -> None:
      print(z)
  |}
    [!&"decorator1"; !&"decorator2"; !&"decorator3"];
  assert_decorators
    {|
    def outer(z: str) -> None:
      @decorator1
      def inner(z: str) -> None:
        print(z)
  |}
    [!&"decorator1"];
  assert_decorators
    {|
    class Foo:
      @decorator1
      def some_method(self, z: str) -> None:
        print(z)
  |}
    [!&"decorator1"];
  ()


let test_inline_decorators context =
  let assert_inlined ?(additional_sources = []) ?(handle = "test.py") source expected =
    let source, environment = setup ~additional_sources ~context ~handle source in
    let decorator_bodies = DecoratorHelper.all_decorator_bodies environment in
    let actual = DecoratorHelper.inline_decorators ~environment ~decorator_bodies source in
    (* Using the same setup code instead of `parse` because the SourcePath `priority` is different
       otherwise. *)
    let expected =
      setup ~additional_sources ~context ~handle expected
      |> fst
      |> DecoratorHelper.sanitize_defines ~strip_decorators:false
    in
    assert_source_equal ~location_insensitive:true expected actual
  in
  assert_inlined
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    @with_logging
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    def foo(y: str) -> None:
      def __original_function(z: str) -> None:
        print(z)

      def __wrapper(y: str) -> None:
        __test_sink(y)
        __original_function(y)

      return __wrapper(y)
  |};
  assert_inlined
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        result = callable(y)
        return result

      return inner

    @with_logging
    def foo(z: str) -> None:
      print(z)
      result = None
      return result
  |}
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        result = callable(y)
        return result

      return inner

    def foo(y: str) -> None:
      def __original_function(z: str) -> None:
        print(z)
        result = None
        return result

      def __wrapper(y: str) -> None:
        __test_sink(y)
        result = __original_function(y)
        return result

      return __wrapper(y)
  |};
  (* `async` decorator. *)
  assert_inlined
    {|
    from typing import Awaitable, Callable

    def with_logging_async(f: Callable[[str], Awaitable[int]]) -> Callable[[str], Awaitable[int]]:

      async def inner(y: str) -> int:
        try:
          result = await f(y)
        except Exception:
          return 42

      return inner

    @with_logging_async
    async def foo(x: str) -> int:
      print(x)
  |}
    {|
    from typing import Awaitable, Callable

    def with_logging_async(f: Callable[[str], Awaitable[int]]) -> Callable[[str], Awaitable[int]]:

      async def inner(y: str) -> int:
        try:
          result = await f(y)
        except Exception:
          return 42

      return inner

    async def foo(y: str) -> int:

      async def __original_function(x: str) -> int:
        print(x)

      async def __wrapper(y: str) -> int:
        try:
          result = await __original_function(y)
        except Exception:
          return 42

      return await __wrapper(y)
  |};
  (* Decorator that types the function parameter as `f: Callable`. *)
  assert_inlined
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_logging(f: Callable) -> Callable:

      def inner(y: str) -> int:
        __test_sink(y)
        f(y)

      return inner

    @with_logging
    def foo(x: str) -> int:
      print(x)
  |}
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_logging(f: Callable) -> Callable:

      def inner(y: str) -> int:
        __test_sink(y)
        f(y)

      return inner

    def foo(y: str) -> int:

      def __original_function(x: str) -> int:
        print(x)

      def __wrapper(y: str) -> int:
        __test_sink(y)
        __original_function(y)

      return __wrapper(y)
  |};
  (* Wrapper function with default values for parameters. *)
  assert_inlined
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str, z: int = 4) -> None:
        __test_sink(y)
        callable(y + z)

      return inner

    @with_logging
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str, z: int = 4) -> None:
        __test_sink(y)
        callable(y + z)

      return inner

    def foo(y: str, z: int = 4) -> None:
      def __original_function(z: str) -> None:
        print(z)

      def __wrapper(y: str, z: int = 4) -> None:
        __test_sink(y)
        __original_function(y + z)

      return __wrapper(y, z)
  |};
  (* Wrapper function with `*args` and `**kwargs`. *)
  assert_inlined
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_logging(f: Callable) -> Callable:

      def inner( *args, **kwargs) -> None:
        __test_sink(args)
        f( *args, **kwargs)

      return inner

    @with_logging
    def foo(x: str) -> None:
      print(x)
  |}
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_logging(f: Callable) -> Callable:

      def inner( *args, **kwargs) -> None:
        __test_sink(args)
        f( *args, **kwargs)

      return inner

    def foo(x: str) -> None:

      def __original_function(x: str) -> None:
        print(x)

      def __wrapper(x: str) -> None:
        __args = (x,)
        __kwargs = {"x": x}
        __test_sink(__args)
        __original_function(x)

      return __wrapper(x)
  |};
  (* ParamSpec. *)
  assert_inlined
    {|
    from typing import Callable
    from pyre_extensions import ParameterSpecification
    from builtins import __test_sink

    P = ParameterSpecification("P")

    def with_logging(f: Callable[P, None]) -> Callable[P, None]:

      def inner( *args: P.args, **kwargs: P.kwargs) -> None:
        f( *args, **kwargs)

      return inner

    @with_logging
    def foo(x: str, y: int) -> None:
      print(x, y)
  |}
    {|
    from typing import Callable
    from pyre_extensions import ParameterSpecification
    from builtins import __test_sink

    P = ParameterSpecification("P")

    def with_logging(f: Callable[P, None]) -> Callable[P, None]:

      def inner( *args: P.args, **kwargs: P.kwargs) -> None:
        f( *args, **kwargs)

      return inner

    def foo(x: str, y: int) -> None:

      def __original_function(x: str, y: int) -> None:
        print(x, y)

      def __wrapper(x: str, y: int) -> None:
        __args = (x, y)
        __kwargs = {"x": x, "y": y}
        __original_function(x, y)

      return __wrapper(x, y)
  |};
  assert_inlined
    {|
    from typing import Callable
    from builtins import __test_sink

    def change_return_type(f: Callable) -> Callable:

      def inner( *args, **kwargs) -> int:
        f( *args, **kwargs)
        return 1

      return inner

    @change_return_type
    def foo(x: str) -> None:
      print(x)
  |}
    {|
    from typing import Callable
    from builtins import __test_sink

    def change_return_type(f: Callable) -> Callable:

      def inner( *args, **kwargs) -> int:
        f( *args, **kwargs)
        return 1

      return inner

    def foo(x: str) -> int:

      def __original_function(x: str) -> None:
        print(x)

      def __wrapper(x: str) -> int:
        __args = (x,)
        __kwargs = {"x": x}
        __original_function(x)
        return 1

      return __wrapper(x)
  |};
  (* Multiple decorators. *)
  assert_inlined
    {|
    from builtins import __test_sink, __test_source
    from typing import Callable

    def with_logging_sink(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    def with_logging_source(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        callable(y + __test_source())

      return inner

    @with_logging_source
    @with_logging_sink
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink, __test_source
    from typing import Callable

    def with_logging_sink(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    def with_logging_source(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        callable(y + __test_source())

      return inner

    def foo(y: str) -> None:
      def __original_function(y: str) -> None:
        def __original_function(z: str) -> None:
          print(z)

        def __wrapper(y: str) -> None:
          __test_sink(y)
          __original_function(y)

        return __wrapper(y)

      def __wrapper(y: str) -> None:
        __original_function(y + __test_source())

      return __wrapper(y)
  |};
  (* Multiple decorators where one decorator fails to apply. *)
  assert_inlined
    {|
    from builtins import __test_sink, __test_source
    from typing import Callable

    def with_logging_sink(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    def with_logging_source(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        callable(y + __test_source())

      return inner

    # We give up on inlining this because it has no inner wrapper function.
    def fails_to_apply(f):
      return f

    @with_logging_source
    @fails_to_apply
    @with_logging_sink
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink, __test_source
    from typing import Callable

    def with_logging_sink(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        callable(y)

      return inner

    def with_logging_source(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        callable(y + __test_source())

      return inner

    # We give up on inlining this because it has no inner wrapper function.
    def fails_to_apply(f):
      return f

    @with_logging_source
    @fails_to_apply
    @with_logging_sink
    def foo(z: str) -> None:
      print(z)
  |};
  (* Decorator factory. *)
  assert_inlined
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_named_logger(logger_name: str) -> Callable[[Callable], Callable]:

      def _inner_decorator(f: Callable) -> Callable:

        def inner( *args: object, **kwargs: object) -> None:
          print(logger_name)
          __test_sink(args)
          f( *args, **kwargs)

        return inner

      return _inner_decorator

    @with_named_logger("foo_logger")
    def foo(x: str) -> None:
      print(x)
  |}
    {|
    from typing import Callable
    from builtins import __test_sink

    def with_named_logger(logger_name: str) -> Callable[[Callable], Callable]:

      def _inner_decorator(f: Callable) -> Callable:

        def inner( *args: object, **kwargs: object) -> None:
          print(logger_name)
          __test_sink(args)
          f( *args, **kwargs)

        return inner

      return _inner_decorator

    def foo(x: str) -> None:
      def __original_function(x: str) -> None:
        print(x)

      def __wrapper(x: str) -> None:
        __args = (x, )
        __kwargs = {"x": x}

        print($parameter$logger_name)
        __test_sink(__args)
        __original_function(x)

      return __wrapper(x)
  |};
  (* Decorator that uses helper functions. *)
  assert_inlined
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        before(y)
        callable(y)
        after(y)

      def my_print(y: str) -> None:
        print("before", y)

      def before(y: str) -> None:
        message = "before"
        my_print(message, y)

      def after(y: str) -> None:
        message = "after"
        my_print(message, y)

      return inner

    @with_logging
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

      def inner(y: str) -> None:
        __test_sink(y)
        before(y)
        callable(y)
        after(y)

      def my_print(y: str) -> None:
        print("before", y)

      def before(y: str) -> None:
        message = "before"
        my_print(message, y)

      def after(y: str) -> None:
        message = "after"
        my_print(message, y)

      return inner

    def foo(y: str) -> None:
      def __original_function(z: str) -> None:
        print(z)

      def __wrapper(y: str) -> None:
        __test_sink(y)
        before(y)
        __original_function(y)
        after(y)

      def my_print(y: str) -> None:
        print("before", y)

      def before(y: str) -> None:
        message = "before"
        my_print(message, y)

      def after(y: str) -> None:
        message = "after"
        my_print(message, y)

      return __wrapper(y)
  |};
  (* Decorator factory with helper functions. *)
  assert_inlined
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_named_logger(logger_name: str) -> Callable[[Callable], Callable]:
      def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

        def inner(y: str) -> None:
          __test_sink(y)
          before(y)
          callable(y)
          after(y)

        def my_print(y: str) -> None:
          print("before", y)

        def before(y: str) -> None:
          message = "before"
          my_print(message, y)

        def after(y: str) -> None:
          message = "after"
          callable(y)
          my_print(message, y)

        return inner

      return with_logging

    @with_named_logger("hello")
    def foo(z: str) -> None:
      print(z)
  |}
    {|
    from builtins import __test_sink
    from typing import Callable

    def with_named_logger(logger_name: str) -> Callable[[Callable], Callable]:
      def with_logging(callable: Callable[[str], None]) -> Callable[[str], None]:

        def inner(y: str) -> None:
          __test_sink(y)
          before(y)
          callable(y)
          after(y)

        def my_print(y: str) -> None:
          print("before", y)

        def before(y: str) -> None:
          message = "before"
          my_print(message, y)

        def after(y: str) -> None:
          message = "after"
          callable(y)
          my_print(message, y)

        return inner

      return with_logging

    def foo(y: str) -> None:
      def __original_function(z: str) -> None:
        print(z)

      def __wrapper(y: str) -> None:
        __test_sink(y)
        before(y)
        __original_function(y)
        after(y)

      def my_print(y: str) -> None:
        print("before", y)

      def before(y: str) -> None:
        message = "before"
        my_print(message, y)

      def after(y: str) -> None:
        message = "after"
        # Uses of `callable` in the helper functions treat it as an unknown variable.
        $parameter$callable(y)
        my_print(message, y)

      return __wrapper(y)
  |};
  assert_inlined
    {|
    from typing import Callable
    from pyre_extensions import ParameterSpecification
    from pyre_extensions.type_variable_operators import Concatenate

    from builtins import __test_sink

    P = ParameterSpecification("P")

    def with_logging(f: Callable[Concatenate[int, P], None]) -> Callable[Concatenate[int, P], None]:

      def inner(first_parameter: int, *args: P.args, **kwargs: P.kwargs) -> None:
        f(first_parameter, *args, **kwargs)
        print(first_parameter)
        print(args, kwargs)

      return inner

    @with_logging
    def foo(x: int, y: str, z: bool) -> None:
      print(x, y, z)
  |}
    {|
    from typing import Callable
    from pyre_extensions import ParameterSpecification
    from pyre_extensions.type_variable_operators import Concatenate

    from builtins import __test_sink

    P = ParameterSpecification("P")

    def with_logging(f: Callable[Concatenate[int, P], None]) -> Callable[Concatenate[int, P], None]:

      def inner(first_parameter: int, *args: P.args, **kwargs: P.kwargs) -> None:
        f(first_parameter, *args, **kwargs)
        print(first_parameter)
        print(args, kwargs)

      return inner

    def foo(x: int, y: str, z: bool) -> None:

      def __original_function(x: int, y: str, z: bool) -> None:
        print(x, y, z)

      def __wrapper(x: int, y: str, z: bool) -> None:
        __args = (y, z)
        __kwargs = {"y": y, "z": z}
        __original_function(x, y, z)
        print(x)
        print(__args, __kwargs)

      return __wrapper(x, y, z)
  |};
  ()


let test_requalify_name _ =
  let open Expression in
  let assert_requalified ~old_qualifier ~new_qualifier name expected =
    assert_equal
      ~cmp:[%equal: Name.t]
      ~printer:[%show: Name.t]
      expected
      (DecoratorHelper.requalify_name ~old_qualifier ~new_qualifier name)
  in
  assert_requalified
    ~old_qualifier:!&"test.foo"
    ~new_qualifier:!&"test.foo.bar"
    (Name.Identifier "$local_test?foo$hello")
    (Name.Identifier "$local_test?foo?bar$hello");
  assert_requalified
    ~old_qualifier:!&"test.foo"
    ~new_qualifier:!&"test.foo.bar"
    (Name.Identifier "$local_test$hello")
    (Name.Identifier "$local_test$hello");
  assert_requalified
    ~old_qualifier:!&"test.foo"
    ~new_qualifier:!&"test.foo.bar"
    (Name.Identifier "hello")
    (Name.Identifier "hello");
  ()


let test_replace_signature _ =
  let assert_signature_replaced ~new_signature given expected =
    match
      ( (expected >>| fun expected -> parse expected |> Source.statements),
        parse given |> Source.statements,
        parse new_signature |> Source.statements )
    with
    | ( expected,
        [{ Node.value = Define given; _ }],
        [
          {
            Node.value =
              Define
                { signature = { name = { Node.value = callee_name; _ }; _ } as new_signature; _ };
            _;
          };
        ] ) ->
        let actual =
          DecoratorHelper.replace_signature_if_always_passing_on_arguments
            ~callee_name:(Reference.show callee_name)
            ~new_signature
            given
        in
        let expected =
          match expected with
          | Some [{ Node.value = Define expected; _ }] -> Some expected
          | _ -> None
        in
        let printer = [%show: Statement.statement option] in
        let equal_optional_statements left right =
          match left, right with
          | Some left, Some right ->
              Statement.location_insensitive_compare
                (Node.create_with_default_location left)
                (Node.create_with_default_location right)
              = 0
          | None, None -> true
          | _ -> false
        in
        assert_equal
          ~cmp:equal_optional_statements
          ~printer
          ~pp_diff:(diff ~print:(fun format x -> Format.fprintf format "%s" (printer x)))
          (expected >>| fun x -> Statement.Statement.Define x)
          (actual >>| fun x -> Statement.Statement.Define x)
    | _ -> failwith "expected one statement each"
  in
  assert_signature_replaced
    ~new_signature:"def foo(y: str, z: int = 7) -> None: ..."
    {|
      def wrapper( *args, **kwargs) -> None:
        foo( *args, **kwargs)
        bar(args)
        baz(kwargs)
  |}
    (Some
       {|
      def wrapper(y: str, z: int = 7) -> None:
        __args = (y, z)
        __kwargs = {"y": y, "z": z}
        foo(y, z)
        bar(__args)
        baz(__kwargs)
  |});
  assert_signature_replaced
    ~new_signature:"def foo(y: str) -> None: ..."
    {|
      def wrapper( *args, **kwargs) -> None:
        foo("extra argument", *args, **kwargs)
        bar(args)
  |}
    None;
  (* Give up if the wrapper has anything more complex than `*args, **kwargs`. *)
  assert_signature_replaced
    ~new_signature:"def foo(y: str) -> None: ..."
    {|
      def wrapper(extra: int, *args, **kwargs) -> None:
        foo( *args, **kwargs)
  |}
    None;
  (* The wrapper still has `*args, **kwargs` but also gives them a type annotation. If it always
     passes on both to the callee, we use the callee's signature. *)
  assert_signature_replaced
    ~new_signature:"def foo(y: str) -> None: ..."
    {|
      def wrapper( *args: int, **kwargs: str) -> None:
        foo( *args, **kwargs)
        bar(args)
  |}
    (Some
       {|
      def wrapper(y: str) -> None:
        __args = (y,)
        __kwargs = {"y": y}
        foo(y)
        bar(__args)
  |});
  (* If the callee expects `args` and `kwargs`, make sure not to confuse them with our synthetic
     locals `__args` and `__kwargs`.

     Note that we conservatively store all the arguments to both `__args` and `__kwargs` so that we
     catch any flows to sinks within the decorator. We are more precise about what we pass to the
     callee since false positives there might be more annoying. *)
  assert_signature_replaced
    ~new_signature:"def foo(y: str, *args: int, **kwargs: str) -> None: ..."
    {|
      def wrapper( *args, **kwargs) -> None:
        foo( *args, **kwargs)
        baz(kwargs)
  |}
    (Some
       {|
      def wrapper(y: str, *args: int, **kwargs: str) -> None:
        __args = (y, *args)
        __kwargs = {"y": y, **kwargs}
        foo(y, *args, **kwargs)
        baz(__kwargs)
  |});
  (* Ensure that the return type is unchanged regardless of the new signature. *)
  assert_signature_replaced
    ~new_signature:"def foo(y: str) -> None: ..."
    {|
      def wrapper( *args, **kwargs) -> int:
        foo( *args, **kwargs)
        return 1
  |}
    (Some
       {|
      def wrapper(y: str) -> int:
        __args = (y,)
        __kwargs = {"y": y}
        foo(y)
        return 1
  |});
  assert_signature_replaced
    ~new_signature:"def foo(some_parameter: int, x: str, y: bool) -> None: ..."
    {|
      def wrapper(some_parameter: int, *args: object, **kwargs: object) -> int:
        foo(some_parameter, *args, **kwargs)
        print(some_parameter)
        print(args, kwargs)
  |}
    (Some
       {|
      def wrapper(some_parameter: int, x: str, y: bool) -> int:
        __args = (x, y)
        __kwargs = {"x": x, "y": y}
        foo(some_parameter, x, y)
        print(some_parameter)
        print(__args, __kwargs)
  |});
  assert_signature_replaced
    ~new_signature:"def foo(prefix1: int, prefix2: str, x: str, y: bool) -> None: ..."
    {|
      def wrapper(some_parameter1: int, some_parameter2: str, *args: object, **kwargs: object) -> int:
        foo(some_parameter1, some_parameter2, *args, **kwargs)
        print(some_parameter1, some_parameter2)
        print(args, kwargs)
  |}
    (Some
       {|
      def wrapper(prefix1: int, prefix2: str, x: str, y: bool) -> int:
        __args = (x, y)
        __kwargs = {"x": x, "y": y}
        foo(prefix1, prefix2, x, y)
        print(prefix1, prefix2)
        print(__args, __kwargs)
  |});
  (* Don't get confused if the original function uses `x` as a parameter name. *)
  assert_signature_replaced
    ~new_signature:"def foo(some_parameter: int, x: str, y: bool) -> None: ..."
    {|
      def wrapper(x: int, *args: object, **kwargs: object) -> int:
        foo(x, *args, **kwargs)
        print(x)
        print(args, kwargs)
  |}
    (Some
       {|
      def wrapper(some_parameter: int, x: str, y: bool) -> int:
        __args = (x, y)
        __kwargs = {"x": x, "y": y}
        foo(some_parameter, x, y)
        print(some_parameter)
        print(__args, __kwargs)
  |});
  assert_signature_replaced
    ~new_signature:"def foo(some_parameter: int, x: str, y: bool) -> None: ..."
    {|
      def wrapper(x: int, *args: object, **kwargs: object) -> int:
        foo(x, "extra argument", *args, **kwargs)
        print(x)
        print(args, kwargs)
  |}
    None;
  assert_signature_replaced
    ~new_signature:"def foo(some_parameter: int, x: str, y: bool) -> None: ..."
    {|
      def wrapper(x: int, *args: object, **kwargs: object) -> int:
        foo("not x", *args, **kwargs)
        print(x)
        print(args, kwargs)
  |}
    None;
  assert_signature_replaced
    ~new_signature:"def foo() -> None: ..."
    {|
      def wrapper(x: int, *args: object, **kwargs: object) -> int:
        foo(x, *args, **kwargs)
        print(x)
        print(args, kwargs)
  |}
    None;
  assert_signature_replaced
    ~new_signature:"def foo(some_parameter: int, *args: int, **kwargs: str) -> None: ..."
    {|
      def wrapper(some_parameter: int, *args: object, **kwargs: object) -> int:
        foo(some_parameter, *args, **kwargs)
        print(some_parameter)
        print(args, kwargs)
  |}
    (Some
       {|
      def wrapper(some_parameter: int, *args: int, **kwargs: str) -> int:
        __args = ( *args,)
        __kwargs = { **kwargs}
        foo(some_parameter, *args, **kwargs)
        print(some_parameter)
        print(__args, __kwargs)
  |});
  ()


let test_rename_local_variables _ =
  let assert_renamed ~pairs given expected =
    match parse expected |> Source.statements, parse given |> Source.statements with
    | [{ Node.value = Define expected; _ }], [{ Node.value = Define given; _ }] ->
        let actual = DecoratorHelper.rename_local_variables ~pairs given in
        let printer = [%show: Statement.statement] in
        assert_equal
          ~cmp:(fun left right ->
            Statement.location_insensitive_compare
              (Node.create_with_default_location left)
              (Node.create_with_default_location right)
            = 0)
          ~printer
          ~pp_diff:(diff ~print:(fun format x -> Format.fprintf format "%s" (printer x)))
          (Statement.Statement.Define expected)
          (Statement.Statement.Define actual)
    | _ -> failwith "expected one statement each"
  in
  assert_renamed
    ~pairs:["y", "y_renamed"; "z", "z_renamed"; "not_found", "not_found_renamed"]
    {|
    def wrapper(y: str, z: int) -> None:
      x = y + z
      foo(y, z)
  |}
    {|
    def wrapper(y: str, z: int) -> None:
      x = y_renamed + z_renamed
      foo(y_renamed, z_renamed)
  |};
  assert_renamed
    ~pairs:["y", "y_renamed"; "y", "y_duplicate"]
    {|
    def wrapper(y: str, z: int) -> None:
      x = y + z
      foo(y, z)
  |}
    {|
    def wrapper(y: str, z: int) -> None:
      x = y + z
      foo(y, z)
  |};
  ()


let () =
  "decoratorHelper"
  >::: [
         "all_decorators" >:: test_all_decorators;
         "inline_decorators" >:: test_inline_decorators;
         "requalify_name" >:: test_requalify_name;
         "replace_signature" >:: test_replace_signature;
         "rename_local_variables" >:: test_rename_local_variables;
       ]
  |> Test.run
