// Jest only (the app's Metro build uses its own React Native preset).
module.exports = {
  presets: [['@babel/preset-env', { targets: { node: 'current' } }], '@babel/preset-typescript'],
};
