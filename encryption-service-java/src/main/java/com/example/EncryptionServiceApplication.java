package com.example;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.vault.authentication.TokenAuthentication;
import org.springframework.vault.client.VaultEndpoint;
import org.springframework.vault.config.AbstractVaultConfiguration;
import org.springframework.vault.core.VaultOperations;
import org.springframework.vault.core.VaultTemplate;
import org.springframework.vault.core.VaultTransitOperations;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.Map;

@SpringBootApplication
public class EncryptionServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(EncryptionServiceApplication.class, args);
    }
}

@Configuration
class VaultConfig extends AbstractVaultConfiguration {
    @Override
    public VaultEndpoint vaultEndpoint() {
        String addr = System.getenv().getOrDefault("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200");
        return VaultEndpoint.from(URI.create(addr));
    }

    @Override
    public org.springframework.vault.authentication.ClientAuthentication clientAuthentication() {
        String token = System.getenv().getOrDefault("VAULT_TOKEN", "root");
        return new TokenAuthentication(token);
    }
}

@RestController
@RequestMapping("/")
class EncryptionController {

    private final VaultTransitOperations transitOperations;
    private final String keyName;

    public EncryptionController(VaultOperations vaultOperations) {
        this.transitOperations = vaultOperations.opsForTransit();
        this.keyName = System.getenv().getOrDefault("KEY_NAME", "demo-key");
    }

    @PostMapping("/encrypt")
    public Map<String, Object> encrypt(@RequestBody Map<String, String> request) {
        String plaintext = request.get("plaintext");
        String name = request.getOrDefault("key", keyName);
        String ciphertext = transitOperations.encrypt(name, plaintext);
        return Map.of("ciphertext", ciphertext, "key_used", name);
    }

    @PostMapping("/decrypt")
    public Map<String, Object> decrypt(@RequestBody Map<String, String> request) {
        String ciphertext = request.get("ciphertext");
        String name = request.getOrDefault("key", keyName);
        String plaintext = transitOperations.decrypt(name, ciphertext);
        return Map.of("plaintext", plaintext, "key_used", name);
    }

    @GetMapping("/status")
    public Map<String, Object> status(@RequestParam(required = false) String key) {
        String name = (key != null) ? key : keyName;
        return Map.of("status", "running", "key", name);
    }
}
