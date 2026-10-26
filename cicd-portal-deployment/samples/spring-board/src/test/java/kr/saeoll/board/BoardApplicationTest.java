package kr.saeoll.board;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

/** API tests on an in-memory H2 database in MariaDB mode (no MariaDB needed in CI). */
@SpringBootTest(properties = "spring.datasource.url=jdbc:h2:mem:board;MODE=MariaDB;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1")
@AutoConfigureMockMvc
class BoardApplicationTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    private String body(Object o) throws Exception {
        return json.writeValueAsString(o);
    }

    @Test
    void healthzAndDbcheck() throws Exception {
        mvc.perform(get("/healthz")).andExpect(status().isOk()).andExpect(content().string("ok"));
        mvc.perform(get("/api/dbcheck")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("ok"));
    }

    @Test
    void crudWithPassword() throws Exception {
        mvc.perform(post("/api/posts").contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm("", "a", "c", "1"))))
                .andExpect(status().isBadRequest());

        String created = mvc.perform(post("/api/posts").contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm("첫 글", "홍길동", "내용", "1234"))))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        long id = json.readTree(created).get("id").asLong();

        mvc.perform(get("/api/posts/" + id)).andExpect(status().isOk())
                .andExpect(jsonPath("$.views").value(1))
                .andExpect(jsonPath("$.passwordHash").doesNotExist());

        mvc.perform(put("/api/posts/" + id).contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm("x", "y", "z", "0000"))))
                .andExpect(status().isForbidden());
        mvc.perform(put("/api/posts/" + id).contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm("수정", "y", "z", "1234"))))
                .andExpect(status().isOk()).andExpect(jsonPath("$.title").value("수정"));

        mvc.perform(get("/api/posts").param("q", "수정"))
                .andExpect(jsonPath("$.total").value(1))
                .andExpect(jsonPath("$.items[0].title").value("수정"));

        mvc.perform(delete("/api/posts/" + id).contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm(null, null, null, "0000"))))
                .andExpect(status().isForbidden());
        mvc.perform(delete("/api/posts/" + id).contentType(MediaType.APPLICATION_JSON)
                .content(body(new PostController.PostForm(null, null, null, "1234"))))
                .andExpect(status().isNoContent());
        mvc.perform(get("/api/posts/" + id)).andExpect(status().isNotFound());
    }
}
