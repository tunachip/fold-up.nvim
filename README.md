# fold-up.nvim

`fold-up.nvim` provides lightweight structural editing commands:

- `:Fold` collapses a sequence onto one line
- `:Unfold` expands a sequence onto one item per line

It recognizes the following common programming patterns:

- comma-separated items in `()`, `[]`, and `{}` (including nested collections)
- semicolon-separated statements in a delimited block
- fluent dot chains, such as Rust method chains

```rust
let value = source.parse().trim().to_string();
```

becomes:

```rust
let value = source
    .parse()
    .trim()
    .to_string();
```

Comma and semicolon delimiters, including a trailing delimiter, are preserved. The lexer ignores quoted strings and line/block comments, so punctuation within them is not treated as a separator.

## Requirements

- Neovim 0.10+

## Installation

### lazy.nvim

```lua
{
  "tunachip/fold-up.nvim",
  config = function()
    require("fold-up").setup({})
  end,
}
```

## Configuration

```lua
require("fold-up").setup({
  fold_command = "Fold",
  unfold_command = "Unfold",
})
```

## Usage

Place the cursor in a delimited expression/block or a multi-line dot chain, then run `:Fold` or `:Unfold`. Alternatively, make a visual selection to constrain the edit to exactly that text.

This is deliberately a text-based structural editor, not a full formatter or syntax-tree parser. For unusual language syntax, select the exact sequence to make the intended scope explicit.
