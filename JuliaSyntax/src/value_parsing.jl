#-------------------------------------------------------------------------------
# This file contains utility functions for converting undecorated source
# strings into Julia values.  For example, string->number, string unescaping, etc.

is_indentation(c) = c == ' ' || c == '\t'

"""
Convert a Julia source code string into a number.
"""
function julia_string_to_number(str::AbstractString, kind)
    str = replace(str, '_'=>"")
    if kind == K"Integer"
        x = Base.tryparse(Int, str)
        if Int === Int32 && isnothing(x)
            x = Base.tryparse(Int64, str)
        end
        if isnothing(x)
            # TODO: flisp parses BigInt and Int128 as string macros rather than
            # literals. Is this necessary or can we get away with using values
            # here?
            x = Base.tryparse(Int128, str)
            if isnothing(x)
                x = Base.parse(BigInt, str)
            end
        end
        return x
    elseif kind == K"Float"
        if 'f' in str
            # This is kind of awful. Should we have a separate Float32 literal
            # type produced by the lexer?  The `f` suffix is nonstandard after all.
            return Base.parse(Float32, replace(str, 'f'=>'e'))
        else
            return Base.parse(Float64, str)
        end
    elseif kind == K"HexInt"
        ndigits = length(str)-2
        return ndigits <= 2  ? Base.parse(UInt8, str)   :
               ndigits <= 4  ? Base.parse(UInt16, str)  :
               ndigits <= 8  ? Base.parse(UInt32, str)  :
               ndigits <= 16 ? Base.parse(UInt64, str)  :
               ndigits <= 32 ? Base.parse(UInt128, str) :
               Base.parse(BigInt, str)
    elseif kind == K"BinInt"
        ndigits = length(str)-2
        return ndigits <= 8   ? Base.parse(UInt8, str)   :
               ndigits <= 16  ? Base.parse(UInt16, str)  :
               ndigits <= 32  ? Base.parse(UInt32, str)  :
               ndigits <= 64  ? Base.parse(UInt64, str)  :
               ndigits <= 128 ? Base.parse(UInt128, str) :
               Base.parse(BigInt, str)
    elseif kind == K"OctInt"
        x = Base.tryparse(UInt64, str)
        if isnothing(x)
            x = Base.tryparse(UInt128, str)
            if isnothing(x)
                x = Base.parse(BigInt, str)
            end
        else
            x = x <= typemax(UInt8)  ? UInt8(x)  :
                x <= typemax(UInt16) ? UInt16(x) :
                x <= typemax(UInt32) ? UInt32(x) :
                x
        end
        return x
    end
end

"""
Process Julia source code escape sequences for raw strings
"""
function unescape_raw_string(io::IO, str::AbstractString, is_cmd::Bool, dedent::Integer)
    delim = is_cmd ? '`' : '"'
    i = firstindex(str)
    lastidx = lastindex(str)
    if i <= lastidx && str[i] != '\n'
        i += dedent
    end
    while i <= lastidx
        c = str[i]
        if c != '\\'
            if c == '\r'
                # convert literal \r and \r\n in strings to \n (issue #11988)
                if i+1 <= lastidx && str[i+1] == '\n'
                    i += 1
                end
                c = '\n'
            end
            write(io, c)
            if c == '\n' && i+1 <= lastidx && str[i+1] != '\n'
                i += dedent
            end
            i = nextind(str, i)
            continue
        end
        # Process \ escape sequences
        j = i
        while str[j] == '\\' && j <= lastidx
            j += 1
        end
        ndelim = j - i
        if j <= lastidx && str[j] == delim
            # Escaping a delimiter
            ndelim = div(ndelim,2)
        end
        for k = 1:ndelim
            write(io, '\\')
        end
        i = j
        if i <= lastidx
            write(io, str[i])
        end
        i = nextind(str, i)
    end
end

"""
Process Julia source code escape sequences for non-raw strings.
`str` should be passed without delimiting quotes.
"""
function unescape_julia_string(io::IO, str::AbstractString, dedent::Integer)
    i = firstindex(str) + dedent
    lastidx = lastindex(str)
    while i <= lastidx
        c = str[i]
        if c != '\\'
            if c == '\r'
                # convert literal \r and \r\n in strings to \n (issue #11988)
                if i+1 <= lastidx && str[i+1] == '\n'
                    i += 1
                end
                c = '\n'
            end
            write(io, c)
            if c == '\n' && i+1 <= lastidx && str[i+1] != '\n'
                i += dedent
            end
            i = nextind(str, i)
            continue
        end
        # Process \ escape sequences.  See also Base.unescape_string which some
        # of this code derives from (but which disallows \` \' \$)
        i += 1
        if i > lastidx
            break
        end
        c = str[i]
        if c == 'x' || c == 'u' || c == 'U'
            n = k = 0
            m = c == 'x' ? 2 :
                c == 'u' ? 4 : 8
            while (k += 1) <= m && i+1 <= lastidx
                nc = str[i+1]
                n = '0' <= nc <= '9' ? n<<4 + (nc-'0') :
                    'a' <= nc <= 'f' ? n<<4 + (nc-'a'+10) :
                    'A' <= nc <= 'F' ? n<<4 + (nc-'A'+10) : break
                i += 1
            end
            if k == 1 || n > 0x10ffff
                u = m == 4 ? 'u' : 'U'
                throw(ArgumentError("invalid $(m == 2 ? "hex (\\x)" :
                                    "unicode (\\$u)") escape sequence"))
            end
            if m == 2 # \x escape sequence
                write(io, UInt8(n))
            else
                print(io, Char(n))
            end
        elseif '0' <= c <= '7'
            k = 1
            n = c-'0'
            while (k += 1) <= 3 && i+1 <= lastidx
                c = str[i+1]
                n = ('0' <= c <= '7') ? n<<3 + c-'0' : break
                i += 1
            end
            if n > 255
                throw(ArgumentError("octal escape sequence out of range"))
            end
            write(io, UInt8(n))
        elseif c == '\n' || c == '\r'
            # Remove \n \r and \r\n newlines + indentation following \
            if c == '\r' && i < lastidx && str[i+1] == '\n'
                i += 1
            end
            while i < lastidx && is_indentation(str[i+1])
                i += 1
            end
        else
            u = # C escapes
                c == 'n' ? '\n' :
                c == 't' ? '\t' :
                c == 'r' ? '\r' :
                c == 'e' ? '\e' :
                c == 'b' ? '\b' :
                c == 'f' ? '\f' :
                c == 'v' ? '\v' :
                c == 'a' ? '\a' :
                # Literal escapes allowed in Julia source
                c == '\\' ? '\\' :
                c == '\'' ? '\'' :
                c == '"' ? '"' :
                c == '$' ? '$' :
                c == '`' ? '`' :
                throw(ArgumentError("Invalid escape sequence \\$c"))
            write(io, u)
        end
        i = nextind(str, i)
    end
end

function unescape_julia_string(str::AbstractString, is_cmd::Bool,
                               is_raw::Bool, dedent::Integer=0)
    io = IOBuffer()
    if is_raw
        unescape_raw_string(io, str, is_cmd, dedent)
    else
        unescape_julia_string(io, str, dedent)
    end
    String(take!(io))
end

# Compute length of longest common prefix of spaces and tabs, in characters
#
# This runs *before* normalization of newlines so that unescaping/normalization
# can happen in a single pass.
#
# TODO: Should we do triplequoted string splitting as part of the main parser?
# It would be conceptually clean if the trivial whitespace was emitted as
# syntax trivia.
#
# flisp: triplequoted-string-indentation-
function triplequoted_string_indentation(strs)
    if isempty(strs)
        return 0
    end
    if last(last(strs)) in ('\n', '\r')
        return 0
    end
    refstr = SubString(strs[1], 1, 0)
    reflen = -1
    for str in strs
        i = 1
        lastidx = lastindex(str)
        while i <= lastidx
            c = str[i]
            if i == 1 || c == '\n' || c == '\r'
                while i <= lastidx
                    c = str[i]
                    (c == '\n' || c == '\r') || break
                    i += 1
                end
                if i <= lastidx
                    # At this point we've found the start of a nonempty line.
                    if reflen < 0
                        # Find indentation we'll use as a reference
                        j = i-1
                        while j < lastidx && is_indentation(str[j+1])
                            j += 1
                        end
                        refstr = SubString(str, i, j)
                        reflen = j - i + 1
                        if j > i
                            i = j
                        end
                    else
                        # Matching indentation with reference, shortening
                        # length if necessary.
                        j = i-1
                        while j+1 <= lastidx && j-i+2 <= reflen
                            if str[j+1] != refstr[j-i+2]
                                break
                            end
                            j += 1
                        end
                        if j-i+1 < reflen
                            reflen = j-i+1
                        end
                        if j > i
                            i = j
                        end
                    end
                end
            end
            i <= lastidx || break
            i = nextind(str, i)
        end
    end
    reflen
end

function process_triple_strings!(strs, is_raw)
    if isempty(strs)
        return strs
    end
    dedent = triplequoted_string_indentation(strs)
    for i = 1:length(strs)
        if i == 1 && strs[1][1] == '\n'
            strs[i] = unescape_julia_string(SubString(strs[i], 2), false, is_raw, dedent)
        else
            strs[i] = unescape_julia_string(strs[i], false, is_raw, dedent)
        end
    end
    strs
end

