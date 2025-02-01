# Mutable Outputs

One of the behaviors which makes Swift Build more complicated than other command
line build systems is that we need to support a number of commands which mutate
their input files.

Some examples of these commands:

1. `strip` will remove symbols from a linked binary.

2. `codesign` may rewrite the binary inside of an input directory, or may add
   additional files to the directory (_CodeSignature subdirectories).

3. `touch` may be used to update a timestamp.

4. `chmod`/`chown` may be used to change ownership or permissions on a file.

These changes are difficult for typical build systems to model well, since they
store the actual output content in the filesystem, so when a command mutates the
filesystem it inherently discards the previous data. That is problematic if the
build system was expecting to be able to look at that data to infer what the
current state is (for incremental build purposes).

The ultimate goal would be to move the storage of the output data out of the
filesystem so that this situation is no longer a special case, but that is a
complex long-term project which Swift Build/llbuild do not yet have support for.

Instead, we support mutable outputs in the following manner:

1. During task construction, we require any command which mutates its input to
   report the exact same node as an input and an output. We also require such
   commands to provide an additional virtual output node which can be used for
   forcing the ordering of the command (see below).

2. During build description construction, we analyze and rewrite the tasks as
   follows:

   * We currently infer "mutating" commands via analyzing the inputs and outputs.

     FIXME: Should we make this explicit?

   * We collect the complete set of mutating commands and mutated files.

   * Once we have found the mutating commands, and thus the set of nodes which
     are mutated, we find the original producer of the file.

   * We rewrite the graph to use "command triggers" between the producer of a
     node and the downstream mutators (in order, see below). Since the
     downstream commands cannot rely on checking the filesystem state of the
     input node in order to properly determine when to rebuild, they use a
     mechanism whereby they will be rerun whenever the upstream command runs.


### Mutator Virtual Output Nodes

Mutating commands are required to produce a virtual output node representing the
command because their outputs are going to be rewritten to *not* include the
actual mutated output (since otherwise this would look like multiple definitions
of an output node to llbuild). When that happens, there must be some other
output node present in order for the build phase ordering implementation to
force the proper ordering of such commands. Without this, some commands might
end up with no outputs whatsoever and never be caused to run.

We could in theory synthesize this node automatically during build description
construction, but that would be much more complicated (since it would also need
to rewrite the build phase ordering edges).


### Order of Mutators

We need to determine the order to run each of the mutating commands. We do this
by requiring that task construction will have arranged for some other strongly
ordered relation between the commands (this is typically a gate producer for
build phase honoring purposes), and then we infer the serial order by
(effectively) doing a topological sort of the mutating commands.

In practice, what we expect to happen is that all mutating commands are strongly
ordered by the gate tasks introduced by the build phases, since almost all of
the mutation is introduced by product postprocessing commands.


### Additional Virtual Outputs

There are several cases where build phases do not suffice to allow the ordering
described above to be enforced. In those cases, we make this work by ensuring
that there is an artificial edge uses virtual nodes between the tasks. For
example, the linker command generates an extra virtual output node we provide as
an input to the dSYM generation task, since they would otherwise be unordered
(ignoring the actual mutated file, that is).

We also sometimes need to add additional virtual output nodes to tasks which
would otherwise not be orderable, for example the MkDir tasks.


### Unsolved Problems


We don't have a working strategy for directory outputs yet, but we don't have
any support for directory outputs.

We don't have any way to communicate what directory outputs are to llbuild.

Downstream edges of the output have to have some other order imposed between the
ultimate mutator and the consumer. We can fix this at the build description
level by adding a synthetic edge, fortunately, even though this probably doesn't
need to be implemented.
