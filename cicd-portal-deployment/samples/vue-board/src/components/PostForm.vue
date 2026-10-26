<script setup>
// Write (no id) or edit (id): edit needs the password given when the post was written.
import { ref, watch } from 'vue';
import { api } from '../api.js';

const props = defineProps({ id: { type: Number, default: null } });
const form = ref({ title: '', author: '', content: '', password: '' });
const errors = ref([]);
const saving = ref(false);

watch(() => props.id, async (id) => {
  errors.value = [];
  form.value = { title: '', author: '', content: '', password: '' };
  if (id) {
    try {
      const p = await api.get(id);
      form.value = { title: p.title, author: p.author, content: p.content, password: '' };
    } catch (e) { errors.value = e.messages || [e.message]; }
  }
}, { immediate: true });

async function save() {
  errors.value = [];
  saving.value = true;
  try {
    const id = props.id ? (await api.update(props.id, form.value)).id : (await api.create(form.value)).id;
    location.hash = `#/posts/${id}`;
  } catch (e) {
    errors.value = e.messages || [e.message];
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <h2>{{ id ? '수정' : '글쓰기' }}</h2>
  <p v-for="e in errors" :key="e" class="error">{{ e }}</p>
  <form @submit.prevent="save">
    <label>제목<input v-model="form.title" type="text" maxlength="200" required /></label>
    <label>작성자<input v-model="form.author" type="text" maxlength="50" required /></label>
    <label>{{ id ? '비밀번호 (작성 시 입력한 값)' : '비밀번호 (수정·삭제용, 4자 이상)' }}
      <input v-model="form.password" type="password" maxlength="64" required />
    </label>
    <label>내용<textarea v-model="form.content" required></textarea></label>
    <button class="btn" type="submit" :disabled="saving">{{ id ? '저장' : '등록' }}</button>
    <a class="btn gray" :href="id ? `#/posts/${id}` : '#/'">취소</a>
  </form>
</template>
