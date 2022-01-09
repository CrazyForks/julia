#-------------------------------------------------------------------------------
"""
`SyntaxToken` is a token covering a contiguous byte range in the input text.
Information about leading whitespace tokens is added for use by the parser.
"""
struct SyntaxToken
    raw::RawToken
    # Flags for leading whitespace
    had_whitespace::Bool
    had_newline::Bool
end

function Base.show(io::IO, tok::SyntaxToken)
    range = string(lpad(first_byte(tok), 3), ":", rpad(last_byte(tok), 3))
    print(io, rpad(range, 17, " "), rpad(kind(tok), 15, " "))
end

kind(tok::SyntaxToken) = tok.raw.kind
first_byte(tok::SyntaxToken) = tok.raw.startbyte + 1
last_byte(tok::SyntaxToken) = tok.raw.endbyte + 1
span(tok::SyntaxToken) = last_byte(tok) - first_byte(tok) + 1

is_dotted(tok::SyntaxToken)    = tok.raw.dotop
is_suffixed(tok::SyntaxToken)  = tok.raw.suffix
is_decorated(tok::SyntaxToken) = is_dotted(tok) || is_suffixed(tok)

Base.:(~)(tok::SyntaxToken, k::Kind) = kind(tok) == k
Base.:(~)(k::Kind, tok::SyntaxToken) = kind(tok) == k

Base.:(==)(tok::SyntaxToken, k::Kind) = (kind(tok) == k && !is_decorated(tok))

#-------------------------------------------------------------------------------

"""
Range in the source text which will become a node in the tree. Can be either a
token (leaf node of the tree) or an interior node, depending on how the
start_mark compares to previous nodes.

TODO: Optimize this data structure?  It's very large at the moment.
"""
struct TaggedRange
    head::SyntaxHead # Kind,flags
    first_byte::Int  # First byte in the input text
    last_byte::Int   # Last byte in the input text
    start_mark::Int  # Index of first emitted range which this range covers
end

head(range::TaggedRange)       = range.head
kind(range::TaggedRange)       = kind(range.head)
flags(range::TaggedRange)      = flags(range.head)
first_byte(range::TaggedRange) = range.first_byte
last_byte(range::TaggedRange)  = range.last_byte
span(range::TaggedRange)       = last_byte(range) - first_byte(range) + 1

struct Diagnostic
    first_byte::Int
    last_byte::Int
    level::Symbol
    message::String
end

first_byte(d::Diagnostic) = d.first_byte
last_byte(d::Diagnostic)  = d.last_byte

function show_diagnostic(io::IO, diagnostic::Diagnostic, source::SourceFile)
    col,prefix = diagnostic.level == :error   ? (:light_red, "Error")      :
                 diagnostic.level == :warning ? (:light_yellow, "Warning") :
                 diagnostic.level == :note    ? (:light_blue, "Note")      :
                 (:normal, "Info")
    printstyled(io, "$prefix: ", color=col)
    print(io, diagnostic.message, ":\n")

    p = first_byte(diagnostic)
    q = last_byte(diagnostic)
    code = source.code
    if q < p || (p == q && code[p] == '\n')
        # An empty or invisible range!  We expand it symmetrically to make it
        # visible.
        p = max(firstindex(code), prevind(code, p))
        q = min(lastindex(code), nextind(code, q))
    end

    # p and q mark the start and end of the diagnostic range. For context,
    # buffer these out to the surrouding lines.
    a,b = source_line_range(source, p, context_lines_before=2, context_lines_after=1)
    c,d = source_line_range(source, q, context_lines_before=1, context_lines_after=2)

    hicol = (100,40,40)

    print(io, source[a:prevind(code, p)])
    # There's two situations, either
    if b >= c
        # The diagnostic range is compact and we show the whole thing
        # a...............
        # .....p...q......
        # ...............b
        _printstyled(io, source[p:q]; color=hicol)
    else
        # Or large and we trucate the code to show only the region around the
        # start and end of the error.
        # a...............
        # .....p..........
        # ...............b
        # (snip)
        # c...............
        # .....q..........
        # ...............d
        _printstyled(io, source[p:b]; color=hicol)
        println(io, "…")
        _printstyled(io, source[c:q]; color=hicol)
    end
    print(io, source[nextind(code,q):d])
    println(io)
end

struct ParseStreamPosition
    input_byte::Int    # Index of next byte in input
    output_index::Int  # Index of last span in output
end

const NO_POSITION = ParseStreamPosition(0,0)

#-------------------------------------------------------------------------------
"""
ParseStream provides an IO interface for the parser. It
- Wraps the lexer with a lookahead buffer
- Removes whitespace and comment tokens, shifting them into the output implicitly

This is simililar in spirit to rust-analyzer's
[TextTreeSink](https://github.com/rust-analyzer/rust-analyzer/blob/4691a0647b2c96cc475d8bbe7c31fe194d1443e7/crates/syntax/src/parsing/text_tree_sink.rs)
"""
mutable struct ParseStream
    lexer::Tokenize.Lexers.Lexer{IOBuffer,RawToken}
    lookahead::Vector{SyntaxToken}
    ranges::Vector{TaggedRange}
    diagnostics::Vector{Diagnostic}
    # First byte of next token
    next_byte::Int
    # Counter for number of peek()s we've done without making progress via a bump()
    peek_count::Int
end

function ParseStream(code)
    lexer = Tokenize.tokenize(code, RawToken)
    ParseStream(lexer,
                Vector{SyntaxToken}(),
                Vector{TaggedRange}(),
                Vector{Diagnostic}(),
                1,
                0)
end

function Base.show(io::IO, mime::MIME"text/plain", stream::ParseStream)
    println(io, "ParseStream at position $(stream.next_byte)")
end

function show_diagnostics(io::IO, stream::ParseStream, code::SourceFile)
    for d in stream.diagnostics
        show_diagnostic(io, d, code)
    end
end

function show_diagnostics(io::IO, stream::ParseStream, code)
    if !isempty(stream.diagnostics)
        show_diagnostics(io, stream, SourceFile(code))
    end
end

#-------------------------------------------------------------------------------
# Stream input interface - the peek_* family of functions

# Buffer up until the next non-whitespace token.
# This can buffer more than strictly necessary when newlines are significant,
# but this is not a big problem.
function _buffer_lookahead_tokens(stream::ParseStream)
    had_whitespace = false
    had_newline    = false
    while true
        raw = Tokenize.Lexers.next_token(stream.lexer)
        k = TzTokens.exactkind(raw)
        was_whitespace = k in (K"Whitespace", K"Comment", K"NewlineWs")
        was_newline    = k == K"NewlineWs"
        had_whitespace |= was_whitespace
        had_newline    |= was_newline
        push!(stream.lookahead, SyntaxToken(raw, had_whitespace, had_newline))
        if !was_whitespace
            break
        end
    end
end

# Find the index of the first nontrivia token in the lookahead buffer.
#
# TODO: Store this as part of _buffer_lookahead_tokens to avoid redoing this
# work all the time!
function _lookahead_index(stream::ParseStream, n::Integer, skip_newlines::Bool)
    i = 1
    while true
        if i > length(stream.lookahead)
            _buffer_lookahead_tokens(stream)
        end
        k = kind(stream.lookahead[i])
        is_skipped =  k ∈ (K"Whitespace", K"Comment") ||
                     (k == K"NewlineWs" && skip_newlines)
        if !is_skipped
            if n == 1
                return i
            end
            n -= 1
        end
        i += 1
    end
end

"""
    peek(stream [, n=1])

Look ahead in the stream `n` tokens, returning the token kind. Comments and
non-newline whitespace are skipped automatically. Whitespace containing a
single newline is returned as kind `K"NewlineWs"` unless `skip_newlines` is
true.
"""
function peek(stream::ParseStream, n::Integer=1; skip_newlines::Bool=false)
    kind(peek_token(stream, n; skip_newlines=skip_newlines))
end

"""
    peek_token(stream [, n=1])

Like `peek`, but return the full token information rather than just the kind.
"""
function peek_token(stream::ParseStream, n::Integer=1; skip_newlines=false)
    stream.peek_count += 1
    if stream.peek_count > 100_000
        error("The parser seems stuck at byte $(stream.next_byte)")
    end
    stream.lookahead[_lookahead_index(stream, n, skip_newlines)]
end

function _peek_equal_to(stream, first_byte, len, str)
    # Humongous but should-be-allocation-free hack: peek at the underlying data
    # buffer. TODO: Attach the code string to the stream so we don't have to
    # dig into the lexer?
    buf = stream.lexer.io.data
    cbuf = codeunits(str)
    for i = 1:len
        if buf[first_byte + i - 1] != cbuf[i]
            return false
        end
    end
    return true
end

"""
Return true if the node already emitted at `pos` covers the string `str`

This is a hack for edge cases where the parser needs access to interpret normal
identifiers as contextural keywords. For example, the special parsing rules for
`@doc` line contination :-(
"""
function peek_behind_str(stream::ParseStream, pos::ParseStreamPosition, str::String)
    s = stream.ranges[pos.output_index]
    return _peek_equal_to(stream, first_byte(s), span(s), str)
end

"""
Return the kind of span which was previously inserted into the output,
defaulting to the most previous nontrivia node.

Retroactively inspecting/modifying the parser's output can be confusing, so
using this function should be avoided where possible.
"""
function peek_behind(stream::ParseStream; skip_trivia::Bool=true)
    kind(peek_token_behind(stream; skip_trivia=skip_trivia))
end

function peek_token_behind(stream::ParseStream; skip_trivia::Bool=true)
    if skip_trivia
        for i = length(stream.ranges):-1:1
            s = stream.ranges[i]
            if !is_trivia(head(s))
                return head(s)
            end
        end
    elseif !isempty(stream.ranges)
        return head(last(stream.ranges))
    end
    return SyntaxHead(K"Nothing", EMPTY_FLAGS)
end

function peek_behind(stream::ParseStream, pos::ParseStreamPosition)
    return kind(stream.ranges[pos.output_index])
end

#-------------------------------------------------------------------------------
# Stream output interface - the `bump_*` and `emit_*` family of functions
#
# Though note bump() really does both input and output

# Bump the next `n` tokens
# flags and remap_kind are applied to any non-trivia tokens
function _bump_n(stream::ParseStream, n::Integer, flags, remap_kind=K"Nothing")
    if n <= 0
        return
    end
    for i = 1:n
        tok = stream.lookahead[i]
        k = kind(tok)
        if k == K"EndMarker"
            break
        end
        is_trivia = k ∈ (K"Whitespace", K"Comment", K"NewlineWs")
        f = is_trivia ? TRIVIA_FLAG : flags
        tok.raw.dotop     && (f |= DOTOP_FLAG)
        k = (is_trivia || remap_kind == K"Nothing") ? k : remap_kind
        range = TaggedRange(SyntaxHead(k, f), first_byte(tok),
                            last_byte(tok), lastindex(stream.ranges)+1)
        push!(stream.ranges, range)
    end
    Base._deletebeg!(stream.lookahead, n)
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    # Defuse the time bomb
    stream.peek_count = 0
end

"""
    bump(stream [, flags=EMPTY_FLAGS];
         skip_newlines=false, error, remap_kind)

Shift the current token from the input to the output, adding the given flags.
"""
function bump(stream::ParseStream, flags=EMPTY_FLAGS; skip_newlines=false,
              error=nothing, remap_kind::Kind=K"Nothing")
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines), flags, remap_kind)
    if !isnothing(error)
        emit(stream, emark, K"error", flags, error=error)
    end
    # Return last token location in output if needed for reset_node!
    return position(stream)
end

"""
Bump comments and whitespace tokens preceding the next token

**Skips newlines** by default.  Set skip_newlines=false to avoid that.
"""
function bump_trivia(stream::ParseStream, flags=EMPTY_FLAGS;
                     skip_newlines=true, error=nothing)
    emark = position(stream)
    _bump_n(stream, _lookahead_index(stream, 1, skip_newlines) - 1, EMPTY_FLAGS)
    if !isnothing(error)
        emit(stream, emark, K"error", flags, error=error)
    end
    return position(stream)
end

"""
Bump an invisible zero-width token into the output

This is useful when surrounding syntax implies the presence of a token.  For
example, `2x` means `2*x` via the juxtoposition rules.
"""
function bump_invisible(stream::ParseStream, kind, flags=EMPTY_FLAGS;
                        error=nothing)
    emit(stream, position(stream), kind, flags, error=error)
    return position(stream)
end

"""
Bump several tokens, gluing them together into a single token

This is for use in special circumstances where the parser needs to resolve
lexing ambiguities. There's no special whitespace handling — bump any
whitespace if necessary with bump_trivia.
"""
function bump_glue(stream::ParseStream, kind, flags, num_tokens)
    span = TaggedRange(SyntaxHead(kind, flags),
                       first_byte(stream.lookahead[1]),
                       last_byte(stream.lookahead[num_tokens]),
                       lastindex(stream.ranges) + 1)
    Base._deletebeg!(stream.lookahead, num_tokens)
    push!(stream.ranges, span)
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    stream.peek_count = 0
    return position(stream)
end

"""
Bump a token, splitting it into several pieces

Wow, this is a hack! It helps resolves the occasional lexing ambiguities. For
example
* Whether .+ should be a single token or a composite (. +)
* Whether ... is splatting (most of the time) or three . tokens in import paths
"""
function bump_split(stream::ParseStream, split_spec...)
    tok = popfirst!(stream.lookahead)
    fbyte = first_byte(tok)
    for (i, (nbyte, kind, flags)) in enumerate(split_spec)
        lbyte = i == length(split_spec) ? last_byte(tok) : fbyte + nbyte - 1
        push!(stream.ranges, TaggedRange(SyntaxHead(kind, flags),
                                         fbyte, lbyte,
                                         lastindex(stream.ranges) + 1))
        fbyte += nbyte
    end
    stream.next_byte = last_byte(last(stream.ranges)) + 1
    stream.peek_count = 0
    # Returning position(stream) like the other bump* methods would be
    # ambiguous here; return nothing instead.
    nothing
end

"""
Reset kind or flags of an existing node in the output stream

This is a hack, but in some limited occasions the trailing syntax may change
the kind or flags of a token in a way which would require unbounded lookahead
in a recursive descent parser. Modifying the output with reset_node! is useful
in those cases.
"""
function reset_node!(stream::ParseStream, mark::ParseStreamPosition;
                     kind=nothing, flags=nothing)
    range = stream.ranges[mark.output_index]
    k = isnothing(kind)  ? (@__MODULE__).kind(range)  : kind
    f = isnothing(flags) ? (@__MODULE__).flags(range) : flags
    stream.ranges[mark.output_index] =
        TaggedRange(SyntaxHead(k, f), first_byte(range), last_byte(range),
                    range.start_mark)
end

function Base.position(stream::ParseStream)
    ParseStreamPosition(stream.next_byte, lastindex(stream.ranges))
end

"""
    emit(stream, mark, kind, flags = EMPTY_FLAGS; error=nothing)

Emit a new text span into the output which covers source bytes from `mark` to
the end of the most recent token which was `bump()`'ed. The starting `mark`
should be a previous return value of `position()`.
"""
function emit(stream::ParseStream, mark::ParseStreamPosition, kind::Kind,
              flags::RawFlags = EMPTY_FLAGS; error=nothing)
    range = TaggedRange(SyntaxHead(kind, flags), mark.input_byte,
                        stream.next_byte-1, mark.output_index+1)
    if !isnothing(error)
        _emit_diagnostic(stream, first_byte(range), last_byte(range), error=error)
    end
    push!(stream.ranges, range)
    return position(stream)
end

function _emit_diagnostic(stream::ParseStream, fbyte, lbyte;
                          error=nothing, warning=nothing)
    message = !isnothing(error)   ? error :
              !isnothing(warning) ? warning :
              error("No message in diagnostic")
    level = !isnothing(error) ? :error : :warning
    push!(stream.diagnostics, Diagnostic(fbyte, lbyte, level, message))
    return nothing
end

"""
Emit a diagnostic at the position of the next token

If `whitespace` is true, the diagnostic is positioned on the whitespace before
the next token. Otherwise it's positioned at the next token as returned by `peek()`.

FIXME: Rename? This doesn't emit normal tokens into the output event list!
"""
function emit_diagnostic(stream::ParseStream; whitespace=false, kws...)
    i = _lookahead_index(stream, 1, true)
    begin_tok_i = i
    end_tok_i = i
    if whitespace
        # It's the whitespace which is the error. Find the range of the current
        # whitespace.
        begin_tok_i = 1
        end_tok_i = is_whitespace(stream.lookahead[i]) ? i : max(1, i-1)
    end
    fbyte = first_byte(stream.lookahead[begin_tok_i])
    lbyte = last_byte(stream.lookahead[end_tok_i])
    _emit_diagnostic(stream, fbyte, lbyte; kws...)
    return nothing
end

function emit_diagnostic(stream::ParseStream, mark::ParseStreamPosition; kws...)
    _emit_diagnostic(stream, mark.input_byte, stream.next_byte-1; kws...)
end

function emit_diagnostic(stream::ParseStream, r::NTuple{2,ParseStreamPosition}; kws...)
    emit_diagnostic(stream, first(r), last(r); kws...)
end

function emit_diagnostic(stream::ParseStream, mark::ParseStreamPosition,
                         end_mark::ParseStreamPosition; kws...)
    _emit_diagnostic(stream, mark.input_byte, end_mark.input_byte-1; kws...)
end

#-------------------------------------------------------------------------------
# Tree construction from the list of text ranges held by ParseStream

"""
    build_tree(::Type{NodeType}, stream::ParseStream;
               wrap_toplevel_as_kind=nothing)

Construct a tree with `NodeType` nodes from a ParseStream using depth-first
traversal. `NodeType` must have the constructors

    NodeType(head::SyntaxHead, span::Integer)
    NodeType(head::SyntaxHead, span::Integer, children::Vector{NodeType})

A single node which covers the input is expected, but if the ParseStream has
multiple nodes at the top level, `wrap_toplevel_as_kind` may be used to wrap
them in a single node.

The tree here is constructed depth-first, but it would also be possible to use
a bottom-up tree builder interface similar to rust-analyzer. (In that case we'd
traverse the list of ranges backward rather than forward.)
"""
function build_tree(::Type{NodeType}, stream::ParseStream;
                    wrap_toplevel_as_kind=nothing) where NodeType
    stack = Vector{NamedTuple{(:range,:node),Tuple{TaggedRange,NodeType}}}()
    for (span_index, range) in enumerate(stream.ranges)
        if kind(range) == K"TOMBSTONE"
            # Ignore invisible tokens which were created but never finalized.
            # See bump_invisible()
            continue
        end

        if isempty(stack) || range.start_mark > stack[end].range.start_mark
            # A leaf node (span covering a single token):
            # [a][b][stack[end]]
            #                   [range]
            node = NodeType(head(range), span(range))
            push!(stack, (range=range, node=node))
            continue
        end
        # An interior node, span covering multiple tokens:
        #
        # [a][b][stack[end]]
        #    [        range]
        #
        # We use start_mark rather than first_byte to determine node overlap.
        # This solve the following ambiguity between invisible nodes 1 and 2:
        # 
        # [a][b]|[...]
        #       |--- invisible node 1
        #       `--- invisible node 2
        #
        # Does node 2 contain node 1? Using start_mark, we can distinguish the
        # cases:
        #
        # [a][b][2][1]  [a][b][2]...
        #                     [   1]
        j = length(stack)
        while j > 1 && range.start_mark < stack[j].range.start_mark
            j -= 1
        end
        children = [stack[k].node for k = j:length(stack)]
        resize!(stack, j-1)
        node = NodeType(head(range), span(range), children)
        push!(stack, (range=range, node=node))
    end
    # show(stdout, MIME"text/plain"(), stack[1].node)
    if length(stack) == 1
        return only(stack).node
    elseif !isnothing(wrap_toplevel_as_kind)
        # Mostly for debugging
        children = [x.node for x in stack]
        return NodeType(SyntaxHead(wrap_toplevel_as_kind, EMPTY_FLAGS), children...)
    else
        error("Found multiple nodes at top level")
    end
end

function parse_all(::Type{GreenNode}, code)
    stream = parse_all(code)
    build_tree(GreenNode, stream)
end


#-------------------------------------------------------------------------------
