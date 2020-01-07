const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = std.c.ast;
const Node = ast.Node;
const Type = ast.Type;
const Tree = ast.Tree;
const TokenIndex = ast.TokenIndex;
const Token = std.c.Token;
const TokenIterator = ast.Tree.TokenList.Iterator;

pub const Error = error{ParseError} || Allocator.Error;

/// Result should be freed with tree.deinit() when there are
/// no more references to any of the tokens or nodes.
pub fn parse(allocator: *Allocator, source: []const u8) !*Tree {
    const tree = blk: {
        // This block looks unnecessary, but is a "foot-shield" to prevent the SegmentedLists
        // from being initialized with a pointer to this `arena`, which is created on
        // the stack. Following code should instead refer to `&tree.arena_allocator`, a
        // pointer to data which lives safely on the heap and will outlive `parse`.
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const tree = try arena.allocator.create(ast.Tree);
        tree.* = .{
            .root_node = undefined,
            .arena_allocator = arena,
            .tokens = undefined,
            .sources = undefined,
        };
        break :blk tree;
    };
    errdefer tree.deinit();
    const arena = &tree.arena_allocator.allocator;

    tree.tokens = ast.Tree.TokenList.init(arena);
    tree.sources = ast.Tree.SourceList.init(arena);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const tree_token = try tree.tokens.addOne();
        tree_token.* = tokenizer.next();
        if (tree_token.id == .Eof) break;
    }
    // TODO preprocess here
    var it = tree.tokens.iterator(0);

    while (true) {
        const tok = it.peek().?.id;
        switch (id) {
            .LineComment,
            .MultiLineComment,
            => {
                _ = it.next();
            },
            else => break,
        }
    }

    var parser = Parser{
        .symbols = Parser.SymbolList.init(allocator),
        .arena = arena,
        .it = &it,
        .tree = tree,
    };
    defer parser.symbols.deinit();

    tree.root_node = try parser.root();
    return tree;
}

const Parser = struct {
    arena: *Allocator,
    it: *TokenIterator,
    tree: *Tree,

    /// only used for scopes
    symbols: SymbolList,
    warnings: bool = true,

    const SymbolList = std.ArrayList(Symbol);

    const Symbol = struct {
        name: []const u8,
        ty: *Type,
    };

    fn pushScope(parser: *Parser) usize {
        return parser.symbols.len;
    }

    fn popScope(parser: *Parser, len: usize) void {
        parser.symbols.resize(len) catch unreachable;
    }

    fn getSymbol(parser: *Parser, tok: TokenIndex) ?*Type {
        const name = parser.tree.slice(tok);
        const syms = parser.symbols.toSliceConst();
        var i = syms.len;
        while (i > 0) : (i -= 1) {
            if (std.mem.eql(u8, name, syms[i].name)) {
                return syms[i].ty;
            }
        }
        return null;
    }

    /// Root <- ExternalDeclaration* eof
    fn root(parser: *Parser) Allocator.Error!*Node.Root {
        const node = try parser.arena.create(Node.Root);
        node.* = .{
            .decls = Node.Root.DeclList.init(parser.arena),
            .eof = undefined,
        };
        while (parser.externalDeclarations() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return node,
        }) |decl| {
            try node.decls.push(decl);
        }
        node.eof = parser.eatToken(.Eof) orelse return node;
        return node;
    }

    /// ExternalDeclaration
    ///     <- DeclSpec Declarator OldStyleDecl* CompoundStmt
    ///     / Declaration
    /// OldStyleDecl <- DeclSpec Declarator (COMMA Declarator)* SEMICOLON
    fn externalDeclarations(parser: *Parser) !?*Node {
        return parser.declarationExtra(false);
    }

    /// Declaration
    ///     <- DeclSpec DeclInit SEMICOLON
    ///     / StaticAssert
    /// DeclInit <- Declarator (EQUAL Initializer)? (COMMA Declarator (EQUAL Initializer)?)*
    fn declaration(parser: *Parser) !?*Node {
        return parser.declarationExtra(true);
    }

    fn declarationExtra(parser: *Parser, local: bool) !?*Node {
        if (try parser.staticAssert()) |decl| return decl;
        var ds = Node.DeclSpec{};
        const got_ds = try parser.declSpec(&ds);
        if (local and !got_ds) {
            // not a declaration
            return null;
        }
        var dr = try parser.declarator();
        // TODO disallow auto and register
        const next_tok = parser.it.peek().?;
        if (next_tok.id == .Eof and !got_ds and dr == null) {
            return null;
        }
        switch (next_tok.id) {
            .Semicolon,
            .Equal,
            .Comma,
            .Eof,
            => {
                while (dr != null) {
                    if (parser.eatToken(.Equal)) |tok| {
                        // TODO typedef
                        // dr.?.init = try parser.expect(initializer, .{
                        //     .ExpectedInitializer = .{ .token = parser.it.index },
                        // });
                    }
                    if (parser.eatToken(.Comma) != null) break;
                    dr = (try parser.declarator()) orelse return parser.err(.{
                        .ExpectedDeclarator = .{ .token = parser.it.index },
                    });
                    // .push(dr);
                }
                const semicolon = try parser.expectToken(.Semicolon);

                // TODO VarDecl, TypeDecl, TypeDef
                return null;
            },
            else => {
                if (dr == null)
                    return parser.err(.{
                        .ExpectedDeclarator = .{ .token = parser.it.index },
                    });
                var old_decls = Node.FnDef.OldDeclList.init(parser.arena);
                while (true) {
                    var old_ds = Node.DeclSpec{};
                    if (!(try parser.declSpec(&old_ds))) {
                        // not old decl
                        break;
                    }
                    var old_dr = (try parser.declarator());
                    // if (old_dr == null)
                    //     try parser.err(.{
                    //         .NoParamName = .{ .token = parser.it.index },
                    //     });
                    // try old_decls.push(decl);
                }
                const body = (try parser.compoundStmt()) orelse return parser.err(.{
                    .ExpectedFnBody = .{ .token = parser.it.index },
                });

                const node = try parser.arena.create(Node.FnDef);
                node.* = .{
                    .decl_spec = ds,
                    .declarator = dr orelse return null,
                    .old_decls = old_decls,
                    .body = @fieldParentPtr(Node.CompoundStmt, "base", body),
                };
                return &node.base;
            },
        }
    }

    /// StaticAssert <- Keyword_static_assert LPAREN ConstExpr COMMA STRINGLITERAL RPAREN SEMICOLON
    fn staticAssert(parser: *Parser) !?*Node {
        const tok = parser.eatToken(.Keyword_static_assert) orelse return null;
        _ = try parser.expectToken(.LParen);
        const const_expr = try parser.constExpr();
        _ = try parser.expectToken(.Comma);
        const str = try parser.expectToken(.StringLiteral);
        _ = try parser.expectToken(.RParen);
        const semicolon = try parser.expectToken(.Semicolon);
        const node = try parser.arena.create(Node.StaticAssert);
        node.* = .{
            .assert = tok,
            .expr = const_expr,
            .semicolon = semicolon,
        };
        return &node.base;
    }

    /// DeclSpec <- (StorageClassSpec / TypeSpec / FnSpec / AlignSpec)*
    /// returns true if any tokens were consumed
    fn declSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        var got = false;
        while ((try parser.storageClassSpec(ds)) or (try parser.typeSpec(&ds.type_spec)) or (try parser.fnSpec(ds)) or (try parser.alignSpec(ds))) {
            got = true;
        }
        return got;
    }

    /// StorageClassSpec
    ///     <- Keyword_typedef / Keyword_extern / Keyword_static / Keyword_thread_local / Keyword_auto / Keyword_register
    fn storageClassSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        blk: {
            if (parser.eatToken(.Keyword_typedef)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Typedef = tok };
            } else if (parser.eatToken(.Keyword_extern)) |tok| {
                if (ds.storage_class != .None)
                    break :blk;
                ds.storage_class = .{ .Extern = tok };
            } else if (parser.eatToken(.Keyword_static)) |tok| {
                if (ds.storage_class != .None)
                    break :blk;
                ds.storage_class = .{ .Static = tok };
            } else if (parser.eatToken(.Keyword_thread_local)) |tok| {
                switch (ds.storage_class) {
                    .None, .Extern, .Static => {},
                    else => break :blk,
                }
                ds.thread_local = tok;
            } else if (parser.eatToken(.Keyword_auto)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Auto = tok };
            } else if (parser.eatToken(.Keyword_register)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Register = tok };
            } else return false;
            return true;
        }
        try parser.warn(.{
            .DuplicateSpecifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// TypeSpec
    ///     <- Keyword_void / Keyword_char / Keyword_short / Keyword_int / Keyword_long / Keyword_float / Keyword_double
    ///     / Keyword_signed / Keyword_unsigned / Keyword_bool / Keyword_complex / Keyword_imaginary /
    ///     / Keyword_atomic LPAREN TypeName RPAREN
    ///     / EnumSpec
    ///     / RecordSpec
    ///     / IDENTIFIER // typedef name
    ///     / TypeQual
    fn typeSpec(parser: *Parser, type_spec: *Node.TypeSpec) !bool {
        while (try parser.typeQual(&type_spec.qual)) {}
        blk: {
            if (parser.eatToken(.Keyword_void)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{ .Void = tok };
                return true;
            } else if (parser.eatToken(.Keyword_char)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Char = .{
                                .char = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        if (int.int != null)
                            break :blk;
                        type_spec.spec = .{
                            .Char = .{
                                .char = tok,
                                .sign = int.sign,
                            },
                        };
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_short)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Short = .{
                                .short = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        if (int.int != null)
                            break :blk;
                        type_spec.spec = .{
                            .Short = .{
                                .short = tok,
                                .sign = int.sign,
                            },
                        };
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_long)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Long = .{
                                .long = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        type_spec.spec = .{
                            .Long = .{
                                .long = tok,
                                .sign = int.sign,
                                .int = int.int,
                            },
                        };
                    },
                    .Long => |*long| {
                        if (long.longlong != null)
                            break :blk;
                        long.longlong = tok;
                    },
                    .Double => |*double| {
                        if (double.long != null)
                            break :blk;
                        double.long = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_int)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Int = .{
                                .int = tok,
                            },
                        };
                    },
                    .Short => |*short| {
                        if (short.int != null)
                            break :blk;
                        short.int = tok;
                    },
                    .Int => |*int| {
                        if (int.int != null)
                            break :blk;
                        int.int = tok;
                    },
                    .Long => |*long| {
                        if (long.int != null)
                            break :blk;
                        long.int = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_signed) orelse parser.eatToken(.Keyword_unsigned)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Int = .{
                                .sign = tok,
                            },
                        };
                    },
                    .Char => |*char| {
                        if (char.sign != null)
                            break :blk;
                        char.sign = tok;
                    },
                    .Short => |*short| {
                        if (short.sign != null)
                            break :blk;
                        short.sign = tok;
                    },
                    .Int => |*int| {
                        if (int.sign != null)
                            break :blk;
                        int.sign = tok;
                    },
                    .Long => |*long| {
                        if (long.sign != null)
                            break :blk;
                        long.sign = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_float)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{
                    .Float = .{
                        .float = tok,
                    },
                };
                return true;
            } else if (parser.eatToken(.Keyword_double)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{
                    .Double = .{
                        .double = tok,
                    },
                };
                return true;
            } else if (parser.eatToken(.Keyword_complex)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Double = .{
                                .complex = tok,
                                .double = null,
                            },
                        };
                    },
                    .Float => |*float| {
                        if (float.complex != null)
                            break :blk;
                        float.complex = tok;
                    },
                    .Double => |*double| {
                        if (double.complex != null)
                            break :blk;
                        double.complex = tok;
                    },
                    else => break :blk,
                }
                return true;
            }
            if (parser.eatToken(.Keyword_bool)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{ .Bool = tok };
                return true;
            } else if (parser.eatToken(.Keyword_atomic)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                _ = try parser.expectToken(.LParen);
                const name = (try parser.typeName()) orelse return parser.err(.{
                    .ExpectedTypeName = .{ .token = parser.it.index },
                });
                type_spec.spec.Atomic = .{
                    .atomic = tok,
                    .typename = name,
                    .rparen = try parser.expectToken(.RParen),
                };
                return true;
            } else if (parser.eatToken(.Keyword_enum)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec.Enum = try parser.enumSpec(tok);
                return true;
            } else if (parser.eatToken(.Keyword_union) orelse parser.eatToken(.Keyword_struct)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec.Record = try parser.recordSpec(tok);
                return true;
            } else if (parser.eatToken(.Identifier)) |tok| {
                const ty = parser.getSymbol(tok) orelse {
                    parser.putBackToken(tok);
                    return false;
                };
                switch (ty.id) {
                    .Enum => |e| {
                        return parser.err(.{
                            .MustUseKwToRefer = .{ .kw = e.tok, .name = tok },
                        });
                    },
                    .Record => |r| {
                        return parser.err(.{
                            .MustUseKwToRefer = .{
                                .kw = r.tok,
                                .name = tok,
                            },
                        });
                    },
                    .Typedef => {
                        type_spec.spec = .{
                            .Typedef = .{
                                .sym = tok,
                                .sym_type = ty,
                            },
                        };
                        return true;
                    },
                    else => {
                        parser.putBackToken(tok);
                        return false;
                    },
                }
            }
        }
        return parser.err(.{
            .InvalidTypeSpecifier = .{
                .token = parser.it.index,
                .type_spec = type_spec,
            },
        });
    }

    /// TypeQual <- Keyword_const / Keyword_restrict / Keyword_volatile / Keyword_atomic
    fn typeQual(parser: *Parser, qual: *Node.TypeQual) !bool {
        blk: {
            if (parser.eatToken(.Keyword_const)) |tok| {
                if (qual.@"const" != null)
                    break :blk;
                qual.@"const" = tok;
            } else if (parser.eatToken(.Keyword_restrict)) |tok| {
                if (qual.atomic != null)
                    break :blk;
                qual.atomic = tok;
            } else if (parser.eatToken(.Keyword_volatile)) |tok| {
                if (qual.@"volatile" != null)
                    break :blk;
                qual.@"volatile" = tok;
            } else if (parser.eatToken(.Keyword_atomic)) |tok| {
                if (qual.atomic != null)
                    break :blk;
                qual.atomic = tok;
            } else return false;
            return true;
        }
        try parser.warn(.{
            .DuplicateQualifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// FnSpec <- Keyword_inline / Keyword_noreturn
    fn fnSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        blk: {
            if (parser.eatToken(.Keyword_inline)) |tok| {
                if (ds.fn_spec != .None)
                    break :blk;
                ds.fn_spec = .{ .Inline = tok };
            } else if (parser.eatToken(.Keyword_noreturn)) |tok| {
                if (ds.fn_spec != .None)
                    break :blk;
                ds.fn_spec = .{ .Noreturn = tok };
            } else return false;
            return true;
        }
        try parser.warn(.{
            .DuplicateSpecifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// AlignSpec <- Keyword_alignas LPAREN (TypeName / ConstExpr) RPAREN
    fn alignSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        if (parser.eatToken(.Keyword_alignas)) |tok| {
            _ = try parser.expectToken(.LParen);
            const node = (try parser.typeName()) orelse (try parser.constExpr());
            if (ds.align_spec != null) {
                try parser.warn(.{
                    .DuplicateSpecifier = .{ .token = parser.it.index },
                });
            }
            ds.align_spec = .{
                .alignas = tok,
                .expr = node,
                .rparen = try parser.expectToken(.RParen),
            };
            return true;
        }
        return false;
    }

    /// EnumSpec <- Keyword_enum IDENTIFIER? (LBRACE EnumField RBRACE)?
    fn enumSpec(parser: *Parser, tok: TokenIndex) !*Node.EnumType {
        const node = try parser.arena.create(Node.EnumType);
        const name = parser.eatToken(.Identifier);
        node.* = .{
            .tok = tok,
            .name = name,
            .body = null,
        };
        const ty = try parser.arena.create(Type);
        ty.* = .{
            .id = .{
                .Enum = node,
            },
        };
        if (name) |some|
            try parser.symbols.append(.{
                .name = parser.tree.slice(some),
                .ty = ty,
            });
        if (parser.eatToken(.LBrace)) |lbrace| {
            var fields = Node.EnumType.FieldList.init(parser.arena);
            try fields.push((try parser.enumField()) orelse return parser.err(.{
                .ExpectedEnumField = .{ .token = parser.it.index },
            }));
            while (parser.eatToken(.Comma)) |_| {
                try fields.push((try parser.enumField()) orelse break);
            }
            node.body = .{
                .lbrace = lbrace,
                .fields = fields,
                .rbrace = try parser.expectToken(.RBrace),
            };
        }
        return node;
    }

    /// EnumField <- IDENTIFIER (EQUAL ConstExpr)? (COMMA EnumField) COMMA?
    fn enumField(parser: *Parser) !?*Node {
        const name = parser.eatToken(.Identifier) orelse return null;
        const node = try parser.arena.create(Node.EnumField);
        node.* = .{
            .name = name,
            .value = null,
        };
        if (parser.eatToken(.Equal)) |eq| {
            node.value = try parser.constExpr();
        }
        return &node.base;
    }

    /// RecordSpec <- (Keyword_struct / Keyword_union) IDENTIFIER? (LBRACE RecordField+ RBRACE)?
    fn recordSpec(parser: *Parser, tok: TokenIndex) !*Node.RecordType {
        const node = try parser.arena.create(Node.RecordType);
        const name = parser.eatToken(.Identifier);
        const is_struct = parser.tree.slice(tok)[0] == 's';
        node.* = .{
            .tok = tok,
            .kind = if (is_struct) .Struct else .Union,
            .name = name,
            .body = null,
        };
        const ty = try parser.arena.create(Type);
        ty.* = .{
            .id = .{
                .Record = node,
            },
        };
        if (name) |some|
            try parser.symbols.append(.{
                .name = parser.tree.slice(some),
                .ty = ty,
            });
        if (parser.eatToken(.LBrace)) |lbrace| {
            var fields = Node.RecordType.FieldList.init(parser.arena);
            while (true) {
                if (parser.eatToken(.RBrace)) |rbrace| {
                    node.body = .{
                        .lbrace = lbrace,
                        .fields = fields,
                        .rbrace = rbrace,
                    };
                    break;
                }
                try fields.push(try parser.recordField());
            }
        }
        return node;
    }

    /// RecordField
    ///     <- TypeSpec* (RecordDeclarator (COMMA RecordDeclarator))? SEMICOLON
    ///     \ StaticAssert
    fn recordField(parser: *Parser) Error!*Node {
        if (try parser.staticAssert()) |decl| return decl;
        var got = false;
        var type_spec = Node.TypeSpec{};
        while (try parser.typeSpec(&type_spec)) got = true;
        if (!got)
            return parser.err(.{
                .ExpectedType = .{ .token = parser.it.index },
            });
        const node = try parser.arena.create(Node.RecordField);
        node.* = .{
            .type_spec = type_spec,
            .declarators = Node.RecordField.DeclaratorList.init(parser.arena),
            .semicolon = undefined,
        };
        while (true) {
            try node.declarators.push(try parser.recordDeclarator());
            if (parser.eatToken(.Comma)) |_| {} else break;
        }

        node.semicolon = try parser.expectToken(.Semicolon);
        return &node.base;
    }

    /// TypeName <- TypeSpec* AbstractDeclarator?
    fn typeName(parser: *Parser) !*Node {

    /// RecordDeclarator <- Declarator? (COLON ConstExpr)?
    fn recordDeclarator(parser: *Parser) !*Node {}

    /// Pointer <- ASTERISK TypeQual* Pointer?
    fn pointer(parser: *Parser) Error!?*Node {
        const asterisk = parser.eatToken(.Asterisk) orelse return null;
        const node = try parser.arena.create(Node.Pointer);
        node.* = .{
            .asterisk = asterisk,
            .qual = .{},
            .pointer = null,
        };
        while (try parser.typeQual(&node.qual)) {}
        node.pointer = try parser.pointer();
        return &node.base;
    }

    const Named = enum {
        Must,
        Allowed,
        Forbidden,
    };

    /// Declarator <- Pointer? DeclaratorSuffix
    /// DeclaratorPrefix
    ///     <- IDENTIFIER // if named != .Forbidden
    ///     / LPAREN Declarator RPAREN
    ///     / (none) // if named != .Must
    /// DeclaratorSuffix
    ///     <. DeclaratorPrefix (LBRACKET ArrayDeclarator? RBRACKET)*
    ///     / DeclaratorPrefix LPAREN (ParamDecl (COMMA ParamDecl)* (COMMA ELLIPSIS)?)? RPAREN
    fn declarator(parser: *Parser, named: Named) Error!?*Node {
        const ptr = try parser.pointer();
        var node: *Node.Declarator = undefined;
        // prefix
        if (parser.eatToken(.LParen)) |lparen| {
            const inner = (try parser.declarator(named)) orelse return parser.err(.{
                .ExpectedDeclarator = .{ .token = lparen + 1 },
            });
            node = try parser.arena.create(Node.Declarator);
            node.* = .{
                .pointer = ptr,
                .prefix = .{
                    .Comples = .{
                        .lparen = lparen,
                        .inner = inner,
                        .rparen = try parser.expectToken(.RParen),
                    },
                },
                .suffix = .None,
            };
        } else if (named != .Forbidden) {
            if (parser.eatToken(.Identifier)) |tok| {
                node = try parser.arena.create(Node.Declarator);
                node.* = .{
                    .pointer = ptr,
                    .prefix = .{ .Simple = tok },
                    .suffix = .None,
                };
            } else if (named == .Must) {
                return parser.err(.{
                    .ExpectedToken = .{ .token = parser.it.index, .expected_id = .Identifier },
                });
            } else {
                return ptr;
            }
        } else {
            node = try parser.arena.create(Node.Declarator);
            node.* = .{
                .pointer = ptr,
                .prefix = .None,
                .suffix = .None,
            };
        }
        // suffix
        if (parser.eatToken(.LParen)) |lparen| {
            node.suffix = .{
                .Fn = .{
                    .lparen = lparen,
                    .params = .Node.Declarator.Params.init(parser.arena),
                    .rparen = undefined,
                },
            };
            try parser.ParamDecl(node);
            node.suffix.Fn.rparen = try parser.expectToken(.RParen);
        } else {
            while (parser.arrayDeclarator()) |arr| {
                if (node.suffix == .None)
                    node.suffix = .{ .Array = .Node.Declarator.Arrays.init(parser.arena) };
                try node.suffix.Array.push(arr);
            }
        }
        if (parser.eatToken(.LParen) orelse parser.eatToken(.LBracket)) |tok|
            return parser.err(.{
                .InvalidDeclarator = .{ .token = tok },
            });
        return node;
    }

    /// ArrayDeclarator
    ///     <- ASTERISK
    ///     / Keyword_static TypeQual* AssignmentExpr
    ///     / TypeQual+ (ASTERISK / Keyword_static AssignmentExpr)
    ///     / TypeQual+ AssignmentExpr?
    ///     / AssignmentExpr
    fn arrayDeclarator(parser: *Parser, dr: *Node.Declarator) !?*Node.Array {
        const lbracket = parser.eatToken(.LBracket) orelse return null;
        const arr = try parser.arena.create(Node.Array);
        arr.* = .{
            .lbracket = lbarcket,
            .inner = .Inferred,
            .rbracket = undefined,
        };
        if (parser.eatToken(.Asterisk)) |tok| {
            arr.inner = .{ .Unspecified = tok };
        } else {
            // TODO
        }
        arr.rbracket = try parser.expectToken(.RBracket);
        return arr;
    }

    /// Params <- ParamDecl (COMMA ParamDecl)* (COMMA ELLIPSIS)?
    /// ParamDecl <- DeclSpec (Declarator / AbstractDeclarator)
    fn paramDecl(parser: *Parser, dr: *Node.Declarator) !void {
        var old_style = false;
        while (true) {
            var ds = Node.DeclSpec;
            if (try parser.declSpec(&ds)) {
                //TODO
            } else if (parser.eatToken(.Identifier)) {
                old_style = true;
            } else if (parser.eatToken(.Ellipsis)) {
                // TODO
            }
        }
    }

    /// Expr <- AssignmentExpr (COMMA Expr)*
    fn expr(parser: *Parser) !*Node {}

    /// AssignmentExpr
    ///     <- ConditionalExpr // TODO recursive?
    ///     / UnaryExpr (EQUAL / ASTERISKEQUAL / SLASHEQUAL / PERCENTEQUAL / PLUSEQUAL / MINUSEQUA /
    ///     / ANGLEBRACKETANGLEBRACKETLEFTEQUAL / ANGLEBRACKETANGLEBRACKETRIGHTEQUAL /
    ///     / AMPERSANDEQUAL / CARETEQUAL / PIPEEQUAL) AssignmentExpr
    fn assignmentExpr(parser: *Parser) !*Node {}

    /// ConstExpr <- ConditionalExpr
    fn constExpr(parser: *Parser) Error!*Node {
        const start = parser.it.index;
        const expression = try parser.conditionalExpr();
        // TODO
        // if (expression == nullor expression.?.value == null)
        //     return parser.err(.{
        //         .ConsExpr = start,
        //     });
        return expression.?;
    }

    /// ConditionalExpr <- LogicalOrExpr (QUESTIONMARK Expr COLON ConditionalExpr)?
    fn conditionalExpr(parser: *Parser) !*Node {}

    /// LogicalOrExpr <- LogicalAndExpr (PIPEPIPE LogicalOrExpr)*
    fn logicalOrExpr(parser: *Parser) !*Node {}

    /// LogicalAndExpr <- BinOrExpr (AMPERSANDAMPERSAND LogicalAndExpr)*
    fn logicalAndExpr(parser: *Parser) !*Node {}

    /// BinOrExpr <- BinXorExpr (PIPE BinOrExpr)*
    fn binOrExpr(parser: *Parser) !*Node {}

    /// BinXorExpr <- BinAndExpr (CARET BinXorExpr)*
    fn binXorExpr(parser: *Parser) !*Node {}

    /// BinAndExpr <- EqualityExpr (AMPERSAND BinAndExpr)*
    fn binAndExpr(parser: *Parser) !*Node {}

    /// EqualityExpr <- ComparisionExpr ((EQUALEQUAL / BANGEQUAL) EqualityExpr)*
    fn equalityExpr(parser: *Parser) !*Node {}

    /// ComparisionExpr <- ShiftExpr (ANGLEBRACKETLEFT / ANGLEBRACKETLEFTEQUAL /ANGLEBRACKETRIGHT / ANGLEBRACKETRIGHTEQUAL) ComparisionExpr)*
    fn comparisionExpr(parser: *Parser) !*Node {}

    /// ShiftExpr <- AdditiveExpr (ANGLEBRACKETANGLEBRACKETLEFT / ANGLEBRACKETANGLEBRACKETRIGHT) ShiftExpr)*
    fn shiftExpr(parser: *Parser) !*Node {}

    /// AdditiveExpr <- MultiplicativeExpr (PLUS / MINUS) AdditiveExpr)*
    fn additiveExpr(parser: *Parser) !*Node {}

    /// MultiplicativeExpr <- UnaryExpr (ASTERISK / SLASH / PERCENT) MultiplicativeExpr)*
    fn multiplicativeExpr(parser: *Parser) !*Node {}

    /// UnaryExpr
    ///     <- LPAREN TypeName RPAREN UnaryExpr
    ///     / Keyword_sizeof LAPERN TypeName RPAREN
    ///     / Keyword_sizeof UnaryExpr
    ///     / Keyword_alignof LAPERN TypeName RPAREN
    ///     / (AMPERSAND / ASTERISK / PLUS / PLUSPLUS / MINUS / MINUSMINUS / TILDE / BANG) UnaryExpr
    ///     / PrimaryExpr PostFixExpr*
    fn unaryExpr(parser: *Parser) !*Node {}

    /// PrimaryExpr
    ///     <- IDENTIFIER
    ///     / INTEGERLITERAL / FLOATLITERAL / STRINGLITERAL / CHARLITERAL
    ///     / LPAREN Expr RPAREN
    ///     / Keyword_generic LPAREN AssignmentExpr (COMMA Generic)+ RPAREN
    fn primaryExpr(parser: *Parser) !*Node {}

    /// Generic
    ///     <- TypeName COLON AssignmentExpr
    ///     / Keyword_default COLON AssignmentExpr
    fn generic(parser: *Parser) !*Node {}

    /// PostFixExpr
    ///     <- LPAREN TypeName RPAREN LBRACE Initializers RBRACE
    ///     / LBRACKET Expr RBRACKET
    ///     / LPAREN (AssignmentExpr (COMMA AssignmentExpr)*)? RPAREN
    ///     / (PERIOD / ARROW) IDENTIFIER
    ///     / (PLUSPLUS / MINUSMINUS)
    fn postFixExpr(parser: *Parser) !*Node {}

    /// Initializers <- ((Designator+ EQUAL)? Initializer COMMA)* (Designator+ EQUAL)? Initializer COMMA?
    fn initializers(parser: *Parser) !*Node {}

    /// Initializer
    ///     <- LBRACE Initializers RBRACE
    ///     / AssignmentExpr
    fn initializer(parser: *Parser) !*Node {}

    /// Designator
    ///     <- LBRACKET ConstExpr RBRACKET
    ///     / PERIOD IDENTIFIER
    fn designator(parser: *Parser) !*Node {}

    /// CompoundStmt <- LBRACE (Declaration / Stmt)* RBRACE
    fn compoundStmt(parser: *Parser) Error!?*Node {
        const lbrace = parser.eatToken(.LBrace) orelse return null;
        const body_node = try parser.arena.create(Node.CompoundStmt);
        body_node.* = .{
            .lbrace = lbrace,
            .statements = Node.CompoundStmt.StmtList.init(parser.arena),
            .rbrace = undefined,
        };
        while ((try parser.declaration()) orelse (try parser.stmt())) |node|
            try body_node.statements.push(node);
        body_node.rbrace = try parser.expectToken(.RBrace);
        return &body_node.base;
    }

    /// Stmt
    ///     <- CompoundStmt
    ///     / Keyword_if LPAREN Expr RPAREN Stmt (Keyword_ELSE Stmt)?
    ///     / Keyword_switch LPAREN Expr RPAREN Stmt
    ///     / Keyword_while LPAREN Expr RPAREN Stmt
    ///     / Keyword_do statement Keyword_while LPAREN Expr RPAREN SEMICOLON
    ///     / Keyword_for LPAREN (Declaration / ExprStmt) ExprStmt Expr? RPAREN Stmt
    ///     / Keyword_default COLON Stmt
    ///     / Keyword_case ConstExpr COLON Stmt
    ///     / Keyword_goto IDENTIFIER SEMICOLON
    ///     / Keyword_continue SEMICOLON
    ///     / Keyword_break SEMICOLON
    ///     / Keyword_return Expr? SEMICOLON
    ///     / IDENTIFIER COLON Stmt
    ///     / ExprStmt
    fn stmt(parser: *Parser) Error!?*Node {
        if (try parser.compoundStmt()) |node| return node;
        if (parser.eatToken(.Keyword_if)) |tok| {
            const node = try parser.arena.create(Node.IfStmt);
            _ = try parser.expectToken(.LParen);
            node.* = .{
                .@"if" = tok,
                .cond = (try parser.expr()) orelse return parser.err(.{
                    .ExpectedExpr = .{ .token = parser.it.index },
                }),
                .@"else" = null,
            };
            _ = try parser.expectToken(.RParen);
            if (parser.eatToken(.Keyword_else)) |else_tok| {
                node.@"else" = .{
                    .tok = else_tok,
                    .stmt = (try parser.stmt()) orelse return parser.err(.{
                        .ExpectedStmt = .{ .token = parser.it.index },
                    }),
                };
            }
            return &node.base;
        }
        // if (parser.eatToken(.Keyword_switch)) |tok| {}
        // if (parser.eatToken(.Keyword_while)) |tok| {}
        // if (parser.eatToken(.Keyword_do)) |tok| {}
        // if (parser.eatToken(.Keyword_for)) |tok| {}
        // if (parser.eatToken(.Keyword_default)) |tok| {}
        // if (parser.eatToken(.Keyword_case)) |tok| {}
        if (parser.eatToken(.Keyword_goto)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .{ .Goto = tok },
                .semicolon = try parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_continue)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .Continue,
                .semicolon = try parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_break)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .Break,
                .semicolon = try parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_return)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .{ .Return = try parser.expr() },
                .semicolon = try parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Identifier)) |tok| {
            if (parser.eatToken(.Colon)) |_| {
                const node = try parser.arena.create(Node.Label);
                node.* = .{
                    .identifier = tok,
                };
                return &node.base;
            }
            parser.putBackToken(tok);
        }
        if (try parser.exprStmt()) |node| return node;
        return null;
    }

    /// ExprStmt <- Expr? SEMICOLON
    fn exprStmt(parser: *Parser) !?*Node {
        const node = try parser.arena.create(Node.ExprStmt);
        const expr_node = try parser.expr();
        const semicolon = if (expr_node != null)
            try parser.expectToken(.Semicolon)
        else
            parser.eatToken(.Semicolon) orelse return null;
        node.* = .{
            .expr = expr_node,
            .semicolon = semicolon,
        };
        return &node.base;
    }

    fn eatToken(parser: *Parser, id: @TagType(Token.Id)) ?TokenIndex {
        while (true) {
            switch ((parser.it.next() orelse return null).id) {
                .LineComment, .MultiLineComment, .Nl => continue,
                else => |next_id| if (next_id == id) {
                    return parser.it.index;
                } else {
                    _ = parser.it.prev();
                    return null;
                },
            }
        }
    }

    fn expectToken(parser: *Parser, id: @TagType(Token.Id)) Error!TokenIndex {
        while (true) {
            switch ((parser.it.next() orelse return error.ParseError).id) {
                .LineComment, .MultiLineComment, .Nl => continue,
                else => |next_id| if (next_id != id) {
                    return parser.err(.{
                        .ExpectedToken = .{ .token = parser.it.index, .expected_id = id },
                    });
                } else {
                    return parser.it.index;
                },
            }
        }
    }

    fn putBackToken(parser: *Parser, putting_back: TokenIndex) void {
        while (true) {
            const prev_tok = parser.it.next() orelse return;
            switch (prev_tok.id) {
                .LineComment, .MultiLineComment, .Nl => continue,
                else => {
                    assert(parser.it.list.at(putting_back) == prev_tok);
                    return;
                },
            }
        }
    }

    fn err(parser: *Parser, msg: ast.Error) Error {
        try parser.tree.msgs.push(.{
            .kind = .Error,
            .inner = msg,
        });
        return error.ParseError;
    }

    fn warn(parser: *Parser, msg: ast.Error) Error!void {
        try parser.tree.msgs.push(.{
            .kind = if (parser.warnings) .Warning else .Error,
            .inner = msg,
        });
        if (!parser.warnings) return error.ParseError;
    }

    fn note(parser: *Parser, msg: ast.Error) Error!void {
        try parser.tree.msgs.push(.{
            .kind = .Note,
            .inner = msg,
        });
    }
};
