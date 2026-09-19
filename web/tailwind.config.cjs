// Prod Tailwind CLI derlemesi (F12 kararı #12): sınıflar Lua view kaynaklarından taranır.
module.exports = {
  darkMode: ["selector", '[data-theme="dark"]'],
  content: ["./src/**/*.lua", "./index.html"],
};
