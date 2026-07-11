# fold-up.nvim

`fold-up.nvim` structurally folds or unfolds a sequence chosen with one Vim-style character argument. It is a focused editing tool, not a formatter.

## Requirements

- Neovim 0.10+

## Installation

```lua
{
  "tunachip/fold-up.nvim",
  config = function()
    require("fold-up").setup({})
  end,
}
```

## Usage

The default mappings wait for one character after the prefix:

| Mapping | Meaning |
| --- | --- |
| `<leader>uf,` | unfold a comma-separated sequence |
| `<leader>uf;` | unfold a semicolon-separated sequence |
| `<leader>uf.` | unfold a fluent dot chain |
| `<leader>uf(` | unfold the nearest enclosing `()` sequence |
| `<leader>uf{` | unfold the nearest enclosing `{}` sequence |
| `<leader>fu,` | fold a comma-separated sequence |
| `<leader>fu;` | fold a semicolon-separated sequence |
| `<leader>fu.` | fold a fluent dot chain |

`(`, `[`, and `{` are *container constraints*: they select that nearest kind of enclosing delimiter and automatically choose comma or semicolon items inside it. `,`, `;`, and `.` explicitly select the separator. This makes ambiguous nested code predictable: use a separator to select what changes, or a delimiter to select where it changes.

The same arguments work with commands:

```vim
:Unfold ,
:Unfold .
:Fold ;
:Unfold {
```

Visual selection constrains the operation to the selected text. Quoted strings and common line/block comments are ignored while finding separators. Trailing comma and semicolon delimiters are preserved.

## Configuration

```lua
require("fold-up").setup({
  fold_command = "Fold",
  unfold_command = "Unfold",
  mappings = {
    unfold = "<leader>uf",
    fold = "<leader>fu",
  },
})
```

Set `mappings = false` to define your own mappings. The Lua API accepts the same argument: `require("fold-up").unfold(".")`.
