const zig = require('tree-sitter-zig/grammar');

/**
 * @file ZX is a framework for building web applications with Zig.
 * @author Nurul Huda (Apon) <me@nurulhudaapon.com>
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar(zig, {
  name: "zx",

  rules: {
    // Extend the Zig expression to include zx blocks
    expression: ($, original) => choice(
      original,
      $.zx_block,
    ),

    // Template string: `text {expr} more text`
    // Similar to JS template literals but without $ sigil
    zx_template_string: $ => seq(
      '`',
      repeat(choice(
        $.zx_template_content,
        $.zx_template_substitution,
      )),
      '`',
    ),

    // Text content inside template string (anything except ` and {)
    zx_template_content: _$ => token(prec(-1, /[^`{]+/)),

    // Interpolation: {expression}
    zx_template_substitution: $ => seq(
      '{',
      field('expression', $.expression),
      '}',
    ),

    // Main zx block - HTML wrapped in parentheses: (<...>...</...>)
    zx_block: $ => seq(
      '(',
      choice(
        $.zx_element,
        $.zx_self_closing_element,
        $.zx_fragment,
      ),
      ')',
    ),

    // HTML element: <tag attrs>children</tag>
    zx_element: $ => seq(
      $.zx_start_tag,
      repeat($.zx_child),
      $.zx_end_tag,
    ),

    // Start tag: <tag attrs>
    zx_start_tag: $ => seq(
      '<',
      field('name', $.zx_tag_name),
      repeat($.zx_attribute),
      '>',
    ),

    // End tag: </tag>
    zx_end_tag: $ => seq(
      '</',
      field('name', $.zx_tag_name),
      '>',
    ),

    // Self-closing element: <tag attrs />
    zx_self_closing_element: $ => seq(
      '<',
      field('name', $.zx_tag_name),
      repeat($.zx_attribute),
      '/>',
    ),

    // Fragment: <>children</>
    zx_fragment: $ => seq(
      '<>',
      repeat($.zx_child),
      '</>',
    ),

    // HTML tag name (e.g., div, main, button, CustomComponent, icons.GitHub)
    zx_tag_name: _$ => /[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*/,

    // HTML/ZX attributes
    zx_attribute: $ => choice(
      $.zx_builtin_attribute,
      $.zx_regular_attribute,
      $.zx_shorthand_attribute,
      $.zx_builtin_shorthand_attribute,
      $.zx_spread_attribute,
    ),

    // Shorthand attribute: {name} expands to name={name}
    // Supports both regular identifiers {class} and quoted {@"data-name"}
    zx_shorthand_attribute: $ => seq(
      '{',
      field('name', $.identifier),
      '}',
    ),

    // Builtin shorthand attribute: @{name} expands to @name={name}
    zx_builtin_shorthand_attribute: $ => seq(
      '@',
      '{',
      field('name', $.identifier),
      '}',
    ),

    // Spread attribute: {..expr} spreads all properties of expr as attributes
    zx_spread_attribute: $ => seq(
      '{',
      '..',
      field('expression', $.expression),
      '}',
    ),

    // Builtin attributes starting with @: @allocator, @rendering, etc.
    zx_builtin_attribute: $ => seq(
      field('name', $.zx_builtin_name),
      '=',
      field('value', $.zx_attribute_value),
    ),

    zx_builtin_name: _$ => /@[a-zA-Z_][a-zA-Z0-9_]*/,

    // Regular HTML attributes: class, id, href, etc.
    zx_regular_attribute: $ => seq(
      field('name', $.zx_attribute_name),
      optional(seq(
        '=',
        field('value', $.zx_attribute_value),
      )),
    ),

    zx_attribute_name: _$ => /[a-zA-Z_:][a-zA-Z0-9_:.-]*/,

    // Attribute value - can be a Zig expression in braces, a string, or a template string
    zx_attribute_value: $ => choice(
      $.zx_expression_block,
      $.zx_string_literal,
      $.zx_template_string,
    ),

    // Zig expression inside braces: {expr}
    zx_expression_block: $ => seq(
      '{',
      field('expression', $.expression),
      '}',
    ),

    // String literal for attributes
    zx_string_literal: _$ => token(choice(
      seq('"', /[^"]*/, '"'),
      seq("'", /[^']*/, "'"),
    )),

    // Children inside zx elements
    zx_child: $ => choice(
      $.zx_element,
      $.zx_self_closing_element,
      $.zx_fragment,
      $.zx_expression_block,
      $.zx_text,
    ),

    // Text content inside HTML elements
    zx_text: _$ => /[^<>{}\n]+/,

    // Special @jsImport for importing JS/React components
    variable_declaration: ($, original) => choice(
      original,
      $.zx_js_import,
    ),

    zx_js_import: $ => seq(
      'const',
      field('name', $.identifier),
      '=',
      '@jsImport',
      '(',
      field('path', $.string),
      ')',
      ';',
    ),
  },
});
