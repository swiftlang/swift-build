# Macro Evaluation

Swift Build supports macro evaluation using `make`-like `$(X)` syntax.  String values that contain macro references are called *macro expressions*, and can be evaluated to obtain literal values within *macro evaluation scopes*.


## Macro Types

There are two fundamental kinds of macro expression: *string* and *string list*.  A third type, *boolean*, is a subtype of *string* whose evaluated literal value is interpreted in the manner of NSString's `boolValue` method.


## Macro Declarations

A *macro declaration* maps a name to a type (string, string list, or boolean) in a macro namespace.  A macro name cannot be empty, and there can be only one declaration of a macro with a particular name in a macro namespace.  It follows that each macro name can be associated with at most one type in a macro namespace.

A macro declaration can also specify an unknown type, which is used for macros that are assigned but never explicitly declared.  They are treated as either strings, string lists, or booleans depending on usage.


## Macro Namespaces

A *macro namespace* defines a domain in which macros can be declared.  Each macro namespace maintains a mapping from macro name to the corresponding macro declaration.  All occurrences of a macro with a given name have the same type within a namespace (but may of course have different types in different namespaces).

Namespaces are also responsible for parsing strings and arrays of strings into macro expressions of the appropriate type.  The parsing semantics depend on the type (string or list) of the macro.  Macro expression parsing may yield parse errors -- an expression of the appropriate type is always returned, but it also carries an optional error description.


## Macro Definition Tables

A *macro definition table* associates macro declarations with lists of parsed macro expressions.  Each of the associated macro expressions can be associated with an optional *condition* that indicates when the expression should be used.


## Macro Evaluation Scopes

A *macro evaluation scope* represents a stack of macro definition tables in association with a set of condition parameter values, allowing unambiguous evaluation of macros to literals.


## Macro Conditions

A *macro condition* allows a macro definition to be used only some of the time.  In particular, a condition specifies a pattern that is matched against the value of that condition within the evaluation scope in which the condition is being tested.


## Macro Condition Parameter

A *macro condition parameter* is a predefined parameter of conditionality in terms of which a macro condition can be specified. Swift Build currently defines five macro condition parameters:  *config*, *sdk*, *variant*, *arch*, and *compiler*.
