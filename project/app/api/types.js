/**
 * @file api/types.js
 * JSDoc type definitions for the JengaAgent API response envelope.
 */

/**
 * @typedef {Object} Meta
 * @property {string} timestamp - ISO 8601 UTC timestamp of the response
 * @property {string} version   - API version string (e.g. "1.0.0")
 */

/**
 * @typedef {Object} ApiError
 * @property {string}  code     - Screaming-snake-case error code (see ERROR_CODES)
 * @property {string}  message  - Human-readable description
 * @property {Object}  [details] - Optional structured details
 */

/**
 * @typedef {Object} ApiEnvelope
 * @template T
 * @property {T|null}        data  - Resource payload (null on error)
 * @property {Meta}          meta  - Response metadata
 * @property {ApiError|null} error - Error information (null on success)
 */

/**
 * String enum of all supported error codes.
 * @readonly
 * @enum {string}
 */
const ERROR_CODES = {
  EPIC_NOT_FOUND:      'EPIC_NOT_FOUND',
  PARSE_ERROR:         'PARSE_ERROR',
  INTERNAL_ERROR:      'INTERNAL_ERROR',
  NOT_FOUND:           'NOT_FOUND',
  INVALID_QUERY_PARAM: 'INVALID_QUERY_PARAM',
};

module.exports = { ERROR_CODES };
