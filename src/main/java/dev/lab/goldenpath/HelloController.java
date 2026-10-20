package dev.lab.goldenpath;

import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final String greeting;

    public HelloController(@Value("${app.greeting:Hello}") String greeting) {
        this.greeting = greeting;
    }

    @GetMapping("/api/hello")
    public Map<String, String> hello() {
        return Map.of("message", greeting);
    }
}

