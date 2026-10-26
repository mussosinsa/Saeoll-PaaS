package kr.saeoll.board;

import com.fasterxml.jackson.annotation.JsonIgnore;

public record Post(long id, String title, String content, String author, long views,
                   String createdAt, String updatedAt, @JsonIgnore String passwordHash) {
}
