# fold-up.nvim

`fold-up.nvim` provides two structural editing commands for comma-separated collections:

- `:Fold` collapses the enclosing selection or bracketed collection onto one line
- `:Unfold` expands the enclosing selection or bracketed collection, recursively unfolding nested collections

The plugin is quote-aware for `'`, `"`, and backticks. It works on either:

- an active visual selection
- the nearest enclosing `()`, `[]`, or `{}` region under the cursor

## Requirements

- Neovim 0.10+

## Installation

### lazy.nvim

```lua
{
  "tunachip/fold-up.nvim",
  config = function()
    require("fold-up").setup({
      fold_command = "Fold",
      unfold_command = "Unfold",
    })
  end,
}
```

### Local development

```lua
{
  dir = "~/Development/fold-up",
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

Place the cursor inside a bracketed collection and run `:Fold` or `:Unfold`.

You can also visually select a region and run the same commands to operate only within that scope.

## Notes

`fold-up.nvim` is intentionally lightweight and text-based. It handles nested bracketed collections and quoted strings well, but it is not a full syntax-tree formatter.

If you find a language-specific edge case, add a minimal example and iterate on the parser before broadening scope.
