Sequent Core
============

Sequent Core is a GHC plugin library based on a sequent calculus. It includes:

*   A set of datatypes for a language expressing function code as *interactions*
    between values and their contexts (*continuations*)
*   A library for writing GHC optimizer plugins using the Sequent Core
    language in place of the built-in Core language
*   Example plugins written using Sequent Core

At the moment, this library is highly experimental. We would appreciate any
feedback at <maurerl@cs.uoregon.edu>.

Introduction
------------

Like most functional languages and λ-calculi, GHC's Core language emphasizes
*values.* An insight of the study of *sequent calculi* is that just as important
are *contexts*—we can see computation as an interaction between a value and its
context. Since the properties of a term, such as strictness, often depend on its
context, giving them equal footing in an AST gives an analysis more information
where it's needed, potentially allowing for significant savings in the size and
complexity of optimization passes and other transforms.

This library reformulates the Core language as a sequent calculus, which we call
Sequent Core. We provide faithful translations between Core and Sequent Core so
that passes operating on Sequent Core can be first-class citizens alongside
traditional Core-to-Core passes. To this end, we also provide a simple wrapper
for writing a GHC plugin using only the Sequent Core representation of module
code.

Overview
--------

After type-checking, GHC distills Haskell code down to a basic language, simply
called Core. A typical bit of (simplified) Core code might be this:

    case f x y of
      True -> g x
      False -> y

If this expression is evaluated, what is the first thing that will happen? This
is not a simple question, especially in Haskell. As this `case` is strict, we
know that the scrutinee `f x y` must be evaluated. (In fact, in Core (but not
in Haskell), *every* `case` is strict.) As function calls are strict in the
function being called, this forces `f x` and, in turn, `f`. So the first action
is to evaluate `f`.

In analyzing Core code, generally one proceeds by recursion, top to bottom. But
the particular *context* of the current expression is often crucial—above, we
needed to know that `f x y` is being forced to conclude that `f` will be
evaluated. Thus the recursive calls need to maintain information about the outer
structure (much as a zipper does). But each recursive function then has to
invent its own representation of a context! Thus simple tasks that recognize
patterns in the code often require substantial ad-hoc bookkeeping.

We would prefer to write the above code like this:

    compute k. <f | $ x
                  ; $ y
                  ; case of
                      True -> <g | $ x; ret k >
                      False -> <y | ret k>>

We will explicate this syntax shortly, but the basic idea is apparent: We
perform a computation in some context we call `k`. The top
of the term says what to do first, namely evaluate `f`. Next, we apply that
value to `x`, and then apply *that* value to `y`. Then, we perform a case
analysis on that result. In the `True` case, we evaluate `g`, apply `x` to it,
then return; in the `False` case, we evaluate y and return it directly. In
either case, the return sends the returned value to the context `k`.

Syntax
------

### Commands

The essential term in Sequent Core is the *command*. It encompasses:
  1. A *term*—usually a variable or a lambda
  1. A *continuation*—the context of the term, i.e. the operations being
     performed on it
  1. A list of *bindings* in scope, each naming a suspended computation

The general syntax we use to represent a command looks like this, where `t` is
a term, `e` is a continuation, and `bs` is a series of bindings (some of
which may be mutually recursive blocks):

    let bs in <t | e>

If there are no bindings, we leave off the `let ... in`.

### Functions

Just as with CPS, each λ-abstraction has an extra argument to bind a 
continuation---the context in which the function is called. Passing a value to
this continuation thus determines the result of the function call.

### Application

Applying a function to an argument is accomplished with an `App` continuation, which
specifies an argument for the computed function. We use the notation `$ t; e`,
where `t` is some argument and `e` is the outer continuation. Thus, if the 
context is `k`, then

    f x y

is expressed as:

    <f | $ x; $ y; ret k>.

This can be read as “Take `f` and apply it to `x`, then apply that to `y`, then
return that to `k`.”

The argument specified is some term. However, a term can be a `Compute` form, 
which wraps a *command*. Since our semantics is call-by-name, this command will
remain unevaluated until forced.

So a slightly more complicated example would be:

    f (g x) (h y)

which becomes:

    <f | $ compute k'. <g | $ x; ret k'>
       ; $ compute k'. <h | $ y; ret k'>
       ; ret k>

### WHNFs

In Core, a saturated data constructor application is irreducible---even though 
it is represented as a fully-applied function, it remains inert unless it's the 
scrutinee of a case. If we wrote Sequent Core this way, then `[True,False]`
would look something like (eliding type arguments):

    compute k. <: | $ compute k1. <: | $ True
                                     ; $ compute k2. <: | $ False
                                                        ; $ []
                                                        ;  ret k2>
                                     ; ret k1>
                  ; ret k>.

Not only is this ugly, but the reduction of a case expression would then mostly
be an interaction between parts of a continuation, rather than an interaction 
between a value and its continuation. Also, to make an application into a term,
we have to use a `compute` abstraction even though there is no actual 
computation being done. Hence we write `[True, False]` as

     (:) True ((:) False []),

much as in Core. Concretely, a data value is `Cons dc args`, where `dc` is the
`DataCon` representing the data constructor and `args` is a list of types and 
Terms.

### Case Analysis

To use a value of a data type, one performs a case analysis. In Sequent Core, we
represent this by a `Case` continuation. Just as an `App` is an application
missing the function, a `Case` is a case expression missing the scrutinee. The 
right-hand side of each case is a command.

    case f x of
      Left  y -> g y
      Right z -> h z

becomes:

    <f | $ x
       ; case of
           Left  y -> <g | $ y; ret k>
           Right z -> <h | $ z; ret k>>

As before, Sequent Core emphasizes the execution order by putting the first
action, the application of `f` to `x`, on top.

### Let Bindings

A command describes an interaction between a value and a continuation. It is an
action *in progress.* Of course, usually a Haskell program has a number of
*suspended* computations as well, waiting to be activated on demand. Since these
`let`-bound computations are not taking part, we don't include them in the
Term or computation part of the command; instead, each command carries a list
of bindings with it. Hence:

    let x = f y in g x z

becomes:

    let
      x = compute k'. <f | $ y; ret k'>
    in
      <g | $ x; $ z; ret k>

### Miscellany

There are a few odds and ends in Core that we must deal with in Sequent Core,
since we aim to translate back and forth faithfully:

*   **Types**  
    For simpler data structures, Core includes types as expressions.
    This allows, for instance, type abstraction and application to use the same
    `Lam` and `App` constructors as for terms. Thus we include `Type` as a
    constructor for Terms; it acts the same way it does in Core.
*   **Coercions**  
    Similarly, Core includes coercion terms for doing type-safe
    casts, so they are Terms in Sequent Core as well.
*   **Casts**  
    Coercions are used by `cast` expressions: The Core expression
    <code>e \`cast\` γ</code> is operationally the
    same as `e`, but its type is altered according to `γ`. We express a cast
    using a continuation, so if `t` is a term, `compute k. <t | cast γ; ret k>`
    is the Sequent Core form of <code>t \`cast\` γ</code>.
*   **Ticks**  
    Finally, Core includes *ticks*, which are essentially markers for
    bookkeeping in the profiler. These wrap expressions, so we include them as
    continuations in a similar manner to casts.

### Summary

Our data types divide the constructors of the `Core` datatype into the three 
types, `Term`, `Cont`, and `Command`. Thus
the Sequent Core syntax is closely related to Core, making the translation
relatively simple. Here are all the constructors of the original `Core` type,
showing where we put each one:

| Constructor |      |      |         |
| :---------- | :--- | :--- | :------ |
| Var         | Term |      |         |
| Lit         | Term |      |         |
| App         | Term | Cont |         |
| Let         |      |      | Command |
| Case        |      | Cont |         |
| Cast        |      | Cont |         |
| Tick        |      | Cont |         |
| Type        | Term |      |         |
| Coercion    | Term |      |         | |

(As noted above, an application will be a simple Term if the function is a data
constructor and there are enough arguments to saturate it.)

An Example
----------

To get a feel for Sequent Core, let us consider a simple function,
this tail-recursive `sum`:

    sum :: [Int] -> Int
    sum = sum' 0
      where
        sum' :: Int -> [Int] -> Int
        sum' a []     = a
        sum' a (x:xs) = sum' (a+x) xs

Here is the Core that is generated by the desugarer (much simplified; to get
more gory details, use GHC's `-ddump-ds` option):

    Main.sum =
      letrec {
        sum' :: Int -> [Int] -> Int
        sum' =
          \ (a :: Int) (ds :: [Int]) ->
            case ds of _ {
              [] -> a;
              : x xs ->
                sum' (+ @Int $fNumInt a x) xs
            }; } in
      sum' (I# 0#)

Largely the structure remains intact, though Core rewrites `while` as `let`,
makes recursive bindings explicit, etc. Also note that `(+)` is called with
*four* arguments—types and constraints are turned into explicit arguments in
Core. Finally, note that the zero is explicitly boxed; Core makes boxing and
unboxing of primitives explicit as well.

Now for the Sequent Core version:

    Main.sum =
       letrec
         {
             sum' :: Int -> [Int] -> Int
             sum' =
               \ (a :: Int) (ds :: [Int]) | (k :: Cont# Int) ->
                 <ds
                 | case as _ of
                     [] -> <a | ret k>
                     x : xs ->
                         <sum'
                         | $ compute (k' :: Cont# Int).
                               <+
                               | $ @Int
                               ; $ $fNumInt
                               ; $ a
                               ; $ x
                               ; ret k'>
                         ; $ xs
                         ; ret k>>
         }
       in compute (k :: Cont# (Int -> Int)). <sum' | $ I# 0#; ret k>>

The Plugin Library
------------------

The `Language.SequentCore.Plugin` module provides a new way of writing GHC
optimization plugins: Rather than write a function taking Core and producing
Core, you can write your plugin as a function taking Sequent Core and producing
Sequent Core, then use the `sequentPass` function to wrap it as a regular
Core-to-Core pass.

### Example Plugin

This package includes a simple plugin, `Language.SequentCore.Dump`, which does
nothing but pretty-print the Sequent Core code to the console. (It is
essentially `ddump-ds` but it outputs Sequent Core rather than Core.) There are
three definitions in the module:

    plugin :: Plugin
    install :: [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
    showSequentCore :: [SeqCoreBind] -> CoreM [SeqCoreBind]

First, there is the `plugin` record:

    plugin :: Plugin
    plugin = defaultPlugin {
      installCoreToDos = install
    }

Any GHC plugin must export a value called `plugin` of type `Plugin` (exported
from the `GhcPlugins` library; see the imports in `Dump.hs`). The
`defaultPlugin` record has suitable defaults, so we need only hook in our code.
The `installCoreToDos` field is a hook that allows the plugin to modify the
Core-to-Core pipeline, so that's what we set.

Next is the `install` function:

    install :: [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
    install _ todos =
      do reinitializeGlobals
         return $ newPass : todos
      where
        newPass  = CoreDoPluginPass "sequent-core-dump" passFunc
        passFunc = sequentPass showSequentCore

The `install` function must take a list of command-line arguments (we ignore
these here) and a list of Core-to-Core passes, and return a modified list of
passes. First, it must call GHC's `reinitializeGlobals` (as a workaround for a
Windows-specific bug). Then it returns the pipeline with a new pass stuck onto
the front. The pass is a `CoreDoPluginPass`, which we give the (arbitrary) name
`"sequent-core-dump"`, defined by the function `passFunc`. Here is where the
Sequent Core library steps in: The `sequentPass` function, exported by
`Language.SequentCore.Plugin`, wraps `showSequentCore` so that it operates on
Core instead of Sequent Core.

Finally, we have the implementation of the pass itself:

    showSequentCore :: [SeqCoreBind] -> CoreM [SeqCoreBind]
    showSequentCore bs = do
      putMsg (ppr_binds_top bs)
      return bs

As advertised, the pass simply dumps the module's bindings to the console, then
returns them unchanged. Now, if you have installed this package, you can see the
Sequent Core for some module `Module.hs` by compiling it with the `-fplugin`
flag:

    $ ghc -c Module.hs -fplugin=Language.SequentCore.Dump

Hopefully this (and the Haddock documentation) should get you started writing
optimization passes using Sequent Core. As this is all in a very early state,
we would appreciate any feedback or ideas at <maurerl@cs.uoregon.edu>. Thanks!

----
Luke Maurer  
Paul Downen  
Iavor S. Diatchki
