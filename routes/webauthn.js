const express = require('express')
const Webauthn = require('webauthn')
const MemoryAdapter = require('webauthn/src/MemoryAdapter')

// Create webauthn
const webauthn = new Webauthn({
  origin: 'http://localhost:3000',
  usernameField: 'username',
  userFields: {
    username: 'username'
  },
  store: new MemoryAdapter(),
  rpName: 'OWASP Org.'
})

const router = express.Router()
router.use('/', webauthn.initialize())

module.exports.routes = router
module.exports.webauthn = webauthn
