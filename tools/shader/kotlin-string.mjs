// SPDX-License-Identifier: AGPL-3.0-only
// A Kotlin raw string literal for any text: `$` and `"""` become template expressions.
const RAW_DELIMITER = '"""';
const DOLLAR_EXPRESSION = '${"$"}';
const RAW_DELIMITER_EXPRESSION = '${"\\"\\"\\""}';

export function kotlinString(value) {
  if (typeof value !== 'string') throw new TypeError('Kotlin string input must be a string');
  return RAW_DELIMITER
    + value.replaceAll('$', DOLLAR_EXPRESSION).replaceAll(RAW_DELIMITER, RAW_DELIMITER_EXPRESSION)
    + RAW_DELIMITER;
}
