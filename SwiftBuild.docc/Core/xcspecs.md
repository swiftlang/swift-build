# Specifications

Swift Build uses external data files known as `xcspec` files for storing the specification data used for various tasks when constructing the build tasks.

> Note: This document is not finished and does not fully reflect how support for some specs was implemented in Swift Build.

 For example, there are specifications which describe each of the tools that are run.

The `xcspec` files are automatically discovered and loaded by Swift Build during initialization.


## Basic Format

`xcspec` files are stored in property lists containing the specification data. Each property list file may contain one or more specs, multiple specs are encoded as elements in an array. Each individual spec is encoded as a dictionary in the property list.

Each property list has several required keys which specify the basic information of the spec, and the remainder of the keys in the dictionary are determined by the exact type of spec. See [Spec Types](#spec-types) for the list of supported types.

The common keys supported by all specs are:

* *"Identifier"* (**required**) (**not inherited**)

    The identifier of the spec. This must be unique within any particular domain, and should generally follow reverse domain name syntax (a la Java).

* *"Type"* (**required**) (**not inherited**)

    The type of the spec. See [Spec Types](#spec-types).

* *"Domain"* (**optional**) (**not inherited**)

    The domain the spec should be registered within. If not provided, the spec will be registered in the domain appropriate to its location, for example specs in the shared locations will be registered in the default domain and specs in platforms will be registered in the platform's domain. See [Spec Types](#spec-types).

* *"BasedOn"* (**optional**) (**not inherited**)

    If provided, a specifier for the spec which this one is "based on" (i.e., the one it inherits from). That spec will be loaded first and its spec properties will be inherited. The exact details and meaning of inheritance depend on the spec type. The base spec **must** be of the same `"Type"` (although the `"Class"` need not be).

  The specifier should be of the form `( domain ':' ) identifier` (e.g,  `macosx:com.apple.tool.foo`), where the domain defaults to the domain of the current spec if not specified.

* *"Class"* (**optional**) (**inherited**)

    If provided, the name of a specific class which should be instantiated to implement the spec behavior, as opposed to using the generic implementation appropriate for the type.

    This key *may be* provided in the the base specification.


<a name="spec-discovery"></a>

## Spec Discovery

Specs are automatically discovered and loaded from plugins. These plugins are provided by the Swift Build project itself.

<a name="spec-types"></a>

## Spec Types

The following types of specs are supported:

* **["Architecture"](#specs-architecture)**

    These specs define actual architecture names or virtual names for groups of architectures.

* **"BuildPhase"**

   > Note: FIXME: Document, or eliminate. This is used by Swift but might not be necessary anymore.

* **["FileType"](#specs-filetype)**

    These specs define information about the file types used by Swift Build.

* **["PackageType"](#specs-packagetype)**

    These specs define information used to implement the different kinds of product packages (i.e., executable, static library, framework, app extensions, etc.).

* **["ProductType"](#specs-producttype)**

    These specs define information about specific product types that can be produced by the build system.

* **"Platform"**

    Each platform also contributes a spec definition properties of the platform.

    > Note: FIXME: We don't currently have these, and may not need them. Eliminate if never used.

* **[*Property Domain Specs*](#specs-propertydomain)**

    Property domain specs are not a concrete type that can be instantiated, but are a common base class shared by the *BuildSystem* specs and the *Tool* specs. This base class factors out the common code for defining information about groups of build settings.

* **"BuildSettings"**

    > Note: FIXME: Document. This is used by Swift, but may no longer be necessary.

* **["BuildSystem"](#specs-buildsystem)**

    These specs define basic information about the build system, for example information about all the build settings.


    Internally, there are separate "build system" definitions for external targets, aggregate, and "native" targets. These correspond to distinct *BuildSystem* specs.

* **["Tool"](#specs-tool)**

    Each tool that can be executed by the build system has a defining spec containing information on the tool, how to invoke it, the settings it supports, and so on.

    The tool type is a superclass of the *Compiler* and *Linker* specs, but can also be concretely instantiated for tools that match neither of those types (for example, `strip` or `dsymutil`).

* **["*Generic* Tool"](#specs-generictool)**

    Generic tool specs do not have a backing class but are (usually) entirely specified by the data in their spec plist.

* **["Compiler"](#specs-compiler)**

    These specs are used for "compiler-like" tools, i.e., tools which operate on and input and transform it into an output of another type.

* **["Linker"](#specs-linker)**

    These specs are used for `ld` and linker-like tools (like `libtool`).


<a name="spec-objecttypes"></a>

## Spec Object Types

The following kinds of objects may be encoded in the spec files.

|Type|Description|
|----|-----------|
|Bool|A boolean value, which should be encoded as either the string `"YES"` or `"NO"` (several other spellings are support for backwards compatibility, but these are the preferred spellings).|
|String|An individual string, encoded as part of the property list format.|
|StringList|A list of strings, encoded as part of the property list format.|
|BuildSettingsDict|A dictionary defining a group of build settings. This should be encoded as a dictionary mapping setting names (and optionally, conditions) to values. Also note that there is no ordering in these objects, which can be a problem when using conditional build settings.|
|CommandLineStringList|A string or list of strings, encoded as part of the property list format. If the string form is used, then it will be separated into arguments following the shell quoting rules.|

> Note: define `BuildSettingsDict` a bit more.

<a name="specs-architecture"></a>

### Architecture Specs

> Note: FIXME: Document Architecture specs.

|Name|Type|Attributes|Description|
|----|----|----------|-----------|
|CompatibilityArchitectures|`CommandLineStringList`|**Optional**|The list of architectures which can are compatible with this one. A `VALID_ARCHS` including this arch will implicitly include all of the ones listed here.|

<a name="specs-filetype"></a>

### FileType Specs

> Note: FIXME: Document FileType specs.

<a name="specs-packagetype"></a>

### PackageType Specs

> Note: FIXME: Completely document PackageType specs.

|Name|Type|Attributes|Description|
|----|----|----------|-----------|
|DefaultBuildSettings|`BuildSettingsDict`|**Required**|The default build settings included for all instances of this package type.|

<a name="specs-producttype"></a>

### ProductType Specs

> Note: FIXME: Completely document ProductType specs.

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| DefaultBuildProperties | `BuildSettingsDict` | **Required** | The default build settings included for all instances of this product type. |

<a name="specs-propertydomain"></a>

### Property Domain Specs

Property domain specs are an abstract class used by all specs which define groups of supported build options (for example, the build system specs and the compiler specs).

The property domain primarily consists of definitions of each of these options, including information on how the option should drive command line arguments for tool specs which make use of the automatic command line generation
infrastructure.

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| Properties | `StringList` | **Optional** | The list of properties associated with this spec, in the order they should be processed. For legacy compatibility these values may be specified under `"Options"`. The list should be an array of items which will be parsed following the information in [Build Option Definitions](#specs-buildoptiondefs).|
| DeletedProperties | `StringList` | **Optional** | The names of build options to remove from the base spec's build option list, when creating the flattened list of options supported by this spec. |

<a name="specs-buildoptiondefs"></a>

### Build Option Definitions

Each build option definition is a property dictionary defining information on
the option.

The following keys are supported:

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| Name | String | **Required** | The name of the option and the build setting that controls it. |
| Type | String | **Optional** **Default="String"** | The string identifying the type of the option. |
| DefaultValue | String | **Optional** | The default value for the build setting, if any. This must always be a string, but it will be parsed as a macro expression appropriate for the type of the option (string or string list). |
| Values | *Custom* | **Required (Enumeration Options)** **Optional (Boolean Options)** **Unsupported (Other)** | This is an array of [Build Option Value Definitions](#specs-buildoptionvaluedefs). This entry is **required** for *Enumeration* option types, **optional** for *boolean* types, and **unsupported** for all other option types. This entry is used to describe the set of possible values for the option, and possibly additional information about how to handle instances of that value (for example, what command line options should be used for values of that type). See [Build Option Value Definitions](#specs-buildoptionvaluedefs) for more information on the supported features. There is no technical reason we cannot support this feature for non-enumeration scalar types. Supporting that is tracked by <rdar://problem/22444795>. |
| CommandLineArgs | *Custom* | **Optional** | This is a string, string list, or dictionary describing how this option should translate to command line arguments. For the string and string list forms, they will be parsed as macro expression strings and subject to macro evaluation, then added to the command line. The macro expression may make use of `$(value)` to refer to the dynamic value of the option. For the dictionary form, the dictionary entries map possible dynamic values to the string or string list forms to substitute -- similar to the handling of `"Values"` but only supporting definition of the command line template. Those individual forms are subject to the same macro evaluation behavior as the string or string list forms of `"CommandLineArgs"`. The value entry of `"<<otherwise>>"` is a special sentinel value that defines the behavior to be used for any dynamic value not explicitly mentioned (that is, a default behavior). If a value appears in `"CommandLineArgs"` and `"Values"`, it **may not** define a command line template form in the `"Values"` entry. For boolean types, only the `"YES"` or `"NO"` values may be defined. |
| AdditionalLinkerArgs | *Custom* | **Optional** | If present, this should be a dictionary mapping possible values to a string or string list supplying additional linker command line arguments to add if the option is enabled. |
| CommandLineFlag | String | **Optional** | If present, defines the flag to use when translating this option to command line arguments. This key **may not** be combined with `"CommandLineArgs"` or `"CommandLinePrefixFlag"`. For boolean options, the given flag will be added to the auto-generated command line if the dynamic value for the option is true. For non-boolean option types, the given flag will be added followed by dynamic value of the option. For list option types, there will be one instance of the flag and the item per item in the dynamic value list. In both cases, the empty string is treated as a special case and signifies that only the dynamic value should appear in the arguments (that is, no empty string is added to the arguments). |
| CommandLinePrefixFlag | String | **Optional** **Unsupported (Boolean Options)** | If present, defines the flag to use when translating this option to command line arguments. This key **may not** be combined with `"CommandLineArgs"` or `"CommandLineFlag"`. The given flag will be added as a single argument joined with the dynamic value of the option. For list option types, there will be one instance of the flag and the item per item in the dynamic value list. |
| Condition | String | **Optional** | If present, a "macro condition expression" which defines when the option should be considered active. This can be used to evaluate a more complicated set of macros to determine when the command line option should be present. |
| FileTypes | StringList | **Optional** | If present, a list of file type identifiers that define when this option should be active. |
| AppearsAfter | String | **Optional** | The name of a build option which this option should immediately succeed. This is useful for controlling the order of generated arguments and the order of options in the UI. |

Supported values for `Type`:

| Type | Description |
|------|-------------|
| Boolean | A boolean build setting. |
| Enumeration | An enumeration build setting, encoded as a string. |
| Path | A build setting which represents a path string. |
| PathList | A build setting which represents a list of path strings. |
| String | A string build setting. |
| StringList | A build setting which is a list of strings. |
| MacroString | A string build setting, which is parsed as a macro expression and subject to macro evaluation when used. |

> Note: For legacy compatibility, the type can be spelled in several other variants, but these should be considered the canonical forms. FIXME: Several other types are supported, but these are the primary ones.

> Note: FIXME: For `CommandLinArgs`, Document string splitting semantics (are these shell-escaped strings?).

<a name="specs-buildoptionvaluedefs"></a>

### Build Option Value Definitions

Each build option value definition is a property dictionary defining information about a particular possible value for a *Boolean* or *Enumeration* build option. The following keys are supported:

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| Value | String | **Required** | The string identifying the value. For boolean types, only the values `"YES"` and `"NO"` are allowed. |
| DisplayName | String | **Optional** | The human readable string used to describe this value. |
| CommandLine | String | **Optional** | If present, defines a "shell"-escaped string to use when translating this option to command line arguments (if the containing option's dynamic value matches this one). The string will be broken into separate individual arguments following the shell rules, and will be subject to macro expression evaluation. The macro expression may make use of `$(value)` to refer to the dynamic value of the option. |
| CommandLineArgs | StringList | **Optional** | If present, defines a list of "shell"-escaped strings to use when translating this option to command line arguments (if the containing option's dynamic value matches this one). Each item in the string list will be broken into separate individual arguments following the shell rules, and will be subject to macro expression evaluation. The macro expression may make use of `$(value)` to refer to the dynamic value of the option. |
| CommandLineFlag | String | **Optional** | If present, defines a single command line flag to pass on the command line when this dynamic value is present for the containing option. |

<a name="specs-buildsystem"></a>

### BuildSystem Specs

> Note: FIXME: Document BuildSystem specs.

<a name="specs-tool"></a>

### Tool Specs

Command-line tool specs support the following keys, in addition to those supported by its base class ([Property Domain Specs](#specs-propertydomain)).

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| SourceFileOption | String | **Optional** | The option to pass to indicate what kind of source files are being processed. This will commonly default to `-c` for typical compilation tools, but alternate uses of tools (for example, the clang static analyzer) will use a different option. |

> Note: FIXME: There are other keys currently used by tool specs which are not yet documented, including: `ExecDescription`, `InputFileTypes`, `FileTypes`, `SynthesizeBuildRule`, and `InputFileGroupings`.

<a name="specs-generictool"></a>

### *"Generic"* Tool Specs

*"Generic"* command line tool specs (those which *do not* use a custom subclass) support additional keys which are used to drive the generic machinery.

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| CommandLine | `CommandLineStringList` | **Required** | This property defines the template which is used to construct command lines for the tool. The template should be a "command line" string list of arguments or placeholders to create the command line from. Each individual argument may either be a macro expression string or a placeholder expression of the form `[NAME]`. The following placeholders are supported: `[exec-path]`, `[input]`, `[inputs]`, `[options]`, `[output]`, and `[special-args]`. This property must be provided by the spec or its base spec. |
| RuleName | `CommandLineStringList` | **Required** | This property defines the template which is used to the "rule info" (short description) for the tool. The template should be a "command line" string list of arguments or placeholders to create the rule info. Each individual argument may either be a macro expression string or a placeholder expression of the form `[NAME]`. The following placeholders are supported: `[input]` and `[output]`. |
| ExecPath | `MacroString` | **Optional** | This property defines the name or path of the executable invoked by the command. |
| EnvironmentVariables | *Custom* | **Optional** | If defined, this property should be a dictionary mapping environment variable names (as strings) to environment variable values (as strings). The values will be subject to macro evaluation. These environment variables will be added to the default set when invoking the command. |
| IncludeInUnionedToolDefaults | `Boolean` | **Optional** **Default=true** | Specifies whether the tool's settings should be included in the unioned tool defaults which are added to all settings tables. |
| Outputs | `StringList` | **Optional** | If present, defines the names of the output files created by the tool. These values will be subject to macro evaluation. They can make use of the special macro `$(OutputPath)` to refer to the automatically output path used in phases such as the resources phase, or they can define the output purely in terms of the input macros. |
| WantsBuildSettingsInEnvironment | `Boolean` | **Optional** **Default=false** **Deprecated** | Specifies whether all of the available build settings should be pushed into the environment for use by the tool. **DO NOT** use this without talking to a member of the build system team, there are usually better ways to accomplish the same task. |
| GeneratedInfoPlistContentFilePath | `MacroString` | **Optional** | If used, specifies a macro string expression which should expand to the path of a file produced as an additional output of the command. The file is expected to be a property list containing additional content to be included in the `Info.plist` for the product being built. |

Placeholders for the `CommandLine` property:

| Placeholder | Description |
|-------------|-------------|
| `[exec-path]` | Expands to the dynamically computed path of the tool. |
| `[input]` | Expands to the path of the first input. May not be used by tools which accept multiple inputs. |
| `[options]` | Expands to the automatically generated list of command line options derived from the tool's `Properties` spec data. |
| `[output]` | Expands to the path of the first output. |
| `[special-args]` | Expands to an tool specific list of arguments (this is an extension point for subclasses which wish to reuse the generic tool machinery). |

Placeholders for the `RuleName` property:

| Placeholder | Description |
|-------------|-------------|
| `[input]` | Expands to the path of the first input. |
| `[output]` | Expands to the path of the first output. |

<a name="specs-compiler"></a>

### Compiler Specs

Compiler specs support the following keys, in addition to those supported by its base class ([Tool Specs](#specs-tool)).

| Name | Type | Attributes | Description |
|------|------|------------|-------------|
| Architectures | `StringList` | **Optional** | A specifier for the architectures the compiler supports. If omitted, the compiler is expected to support any architecture. If present, the value must be either a string list containing the exact names of real architectures which are supported, or it can be the sentinel value `$(VALID_ARCHS)` indicating that the compiler supports all current valid architectures. |

> Note: FIXME: Why is that necessary? Wouldn't such a compiler just declare itself as supporting any architecture?

<a name="specs-linker"></a>

### Linker Specs

> Note: FIXME: Document Linker specs.
