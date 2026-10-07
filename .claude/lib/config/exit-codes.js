/**
 * lib/config/exit-codes.js - the one exit-code table for `jenga config` (E68_S02_T01)
 *
 * The table is read from templates/config-descriptor-schema.json (`exit_codes`), the same place
 * project/documentation/config-descriptors.md says it is recorded, so get, set, the interactive flow and the
 * helper scripts cannot drift from the schema. Nothing here is a second copy of the numbers.
 *
 *   EXIT.ok 0, EXIT.usage 2, EXIT.unknown_file_or_key 3, EXIT.invalid_value 4, EXIT.read_only_key 5,
 *   EXIT.config_unavailable 6.  The helper scripts additionally use 1 (EXIT_UNEXPECTED) for a failure that is not
 *   the caller's fault, such as an invalid descriptor.
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { readFileSync } from "fs";
import { schemaPath } from "./paths.js";

export const EXIT_UNEXPECTED = 1;

const REQUIRED = ["ok", "usage", "unknown_file_or_key", "invalid_value", "read_only_key", "config_unavailable"];

function loadTable() {
  const table = JSON.parse(readFileSync(schemaPath(), "utf8")).exit_codes;
  for (const name of REQUIRED) {
    if (!table || !Number.isInteger(table[name])) {
      throw new Error(`templates/config-descriptor-schema.json: exit_codes.${name} must be an integer`);
    }
  }
  return Object.freeze(Object.assign({}, table));
}

export const EXIT = loadTable();
