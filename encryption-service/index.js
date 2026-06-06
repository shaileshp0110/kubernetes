const express = require('express');
const axios = require('axios');
const app = express();
const port = process.env.PORT || 3000;

app.use(express.json());

const VAULT_ADDR = process.env.VAULT_ADDR || 'http://vault.vault.svc.cluster.local:8200';
const VAULT_TOKEN = process.env.VAULT_TOKEN || 'root';
const KEY_NAME = process.env.KEY_NAME || 'demo-key';

const vault = axios.create({
  baseURL: `${VAULT_ADDR}/v1`,
  headers: { 'X-Vault-Token': VAULT_TOKEN }
});

// Encrypt endpoint
app.post('/encrypt', async (req, res) => {
  try {
    const { plaintext, key } = req.body;
    const keyName = key || KEY_NAME;
    if (!plaintext) return res.status(400).send({ error: 'plaintext is required' });

    // Vault expects base64 encoded plaintext for transit engine
    const base64Plaintext = Buffer.from(plaintext).toString('base64');

    const response = await vault.post(`/transit/encrypt/${keyName}`, {
      plaintext: base64Plaintext
    });

    res.send({
      ciphertext: response.data.data.ciphertext,
      key_version: response.data.data.key_version,
      key_used: keyName
    });
  } catch (error) {
    console.error('Encryption error:', error.response?.data || error.message);
    res.status(500).send({ error: 'Encryption failed', details: error.response?.data || error.message });
  }
});

// Decrypt endpoint
app.post('/decrypt', async (req, res) => {
  try {
    const { ciphertext, key } = req.body;
    const keyName = key || KEY_NAME;
    if (!ciphertext) return res.status(400).send({ error: 'ciphertext is required' });

    const response = await vault.post(`/transit/decrypt/${keyName}`, {
      ciphertext
    });

    // Vault returns base64 encoded plaintext
    const decodedPlaintext = Buffer.from(response.data.data.plaintext, 'base64').toString('utf8');

    res.send({
      plaintext: decodedPlaintext,
      key_used: keyName
    });
  } catch (error) {
    console.error('Decryption error:', error.response?.data || error.message);
    res.status(500).send({ error: 'Decryption failed', details: error.response?.data || error.message });
  }
});

// Status endpoint to check key metadata
app.get('/status', async (req, res) => {
  try {
    const keyName = req.query.key || KEY_NAME;
    const response = await vault.get(`/transit/keys/${keyName}`);
    const keyData = response.data.data;
    res.send({
      key_name: keyName,
      type: keyData.type,
      latest_version: keyData.latest_version,
      min_decryption_version: keyData.min_decryption_version,
      versions: Object.keys(keyData.keys)
    });
  } catch (error) {
    res.status(500).send({ error: 'Failed to fetch key status', details: error.response?.data || error.message });
  }
});

app.listen(port, () => {
  console.log(`Encryption service listening at http://localhost:${port}`);
  console.log(`Vault Address: ${VAULT_ADDR}`);
});
