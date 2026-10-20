package dev.lab.goldenpath;

import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.Test;

class HelloControllerTest {

    @Test
    void returnsConfiguredGreeting() {
        HelloController controller = new HelloController("Hi");
        assertEquals("Hi", controller.hello().get("message"));
    }
}
