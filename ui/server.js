const express = require('express');
const path = require('path');
const app = express();
const PORT = process.env.PORT || 8080;

app.use(express.static(path.join(__dirname, 'www')));

// SPA fallback — serve index.html for all unmatched routes
app.get('/*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'www', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`UI server running on port ${PORT}`);
});
