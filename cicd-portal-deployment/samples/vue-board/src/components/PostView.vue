<script setup>
import { ref, watch } from 'vue';
import { api } from '../api.js';

const props = defineProps({ id: { type: Number, required: true } });
const post = ref(null);
const error = ref('');
const password = ref('');

watch(() => props.id, async (id) => {
  error.value = '';
  try { post.value = await api.get(id); } catch (e) { post.value = null; error.value = e.message; }
}, { immediate: true });

async function remove() {
  error.value = '';
  try { await api.remove(props.id, password.value); location.hash = '#/'; }
  catch (e) { error.value = e.message; }
}
</script>

<template>
  <p v-if="error" class="error">{{ error }}</p>
  <template v-if="post">
    <h2>{{ post.title }}</h2>
    <p class="meta">
      {{ post.author }} · {{ post.createdAt }}<span v-if="post.updatedAt"> (수정 {{ post.updatedAt }})</span> · 조회 {{ post.views }}
    </p>
    <div class="content">{{ post.content }}</div>
    <p><a class="btn gray" href="#/">목록</a> <a class="btn gray" :href="`#/posts/${post.id}/edit`">수정</a></p>
    <form @submit.prevent="remove">
      <input v-model="password" type="password" placeholder="삭제하려면 작성 시 비밀번호 입력" required />
      <button class="btn red" type="submit">삭제</button>
    </form>
  </template>
  <p v-else-if="error"><a href="#/">목록</a></p>
</template>
