package kr.saeoll.app;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ApplicationTest {

    @Test
    void healthz() {
        assertEquals("ok", new Application().healthz());
    }
}
