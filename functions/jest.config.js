/** Jest 設定（ts-jest で TypeScript を直接テスト） */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.test.json' }],
  },
  // jose@6 は ESM 専用で Jest 29(CJS) が読めないためスタブ化（理由は test/stubs/jose.js）
  moduleNameMapper: { '^jose$': '<rootDir>/test/stubs/jose.js' },
  clearMocks: true,
  verbose: true,
};
