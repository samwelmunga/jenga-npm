/**
 * @file api/response.js
 * Helper functions for building consistent API response envelopes.
 */

const API_VERSION = '1.0.0';

/**
 * Build a success envelope.
 * @template T
 * @param {T} data
 * @param {Object} [extraMeta] - Additional meta fields to merge
 * @returns {import('./types').ApiEnvelope<T>}
 */
function successResponse(data, extraMeta = {}) {
  return {
    data,
    meta: {
      timestamp: new Date().toISOString(),
      version: API_VERSION,
      ...extraMeta,
    },
    error: null,
  };
}

/**
 * Build an error envelope.
 * @param {string} code    - Error code from ERROR_CODES
 * @param {string} message - Human-readable message
 * @param {Object} [details]
 * @returns {import('./types').ApiEnvelope<null>}
 */
function errorResponse(code, message, details) {
  const err = { code, message };
  if (details !== undefined) err.details = details;
  return {
    data: null,
    meta: {
      timestamp: new Date().toISOString(),
      version: API_VERSION,
    },
    error: err,
  };
}

module.exports = { successResponse, errorResponse, API_VERSION };
