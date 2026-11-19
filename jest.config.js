/** @type {import('jest').Config} */
module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/src', '<rootDir>/plugin'],
  testMatch: ['**/__tests__/**/*.test.ts'],
  // The tests replace react-native with a fake TurboModuleRegistry; the real package is never loaded.
  modulePathIgnorePatterns: ['<rootDir>/lib', '<rootDir>/plugin/build'],
};
