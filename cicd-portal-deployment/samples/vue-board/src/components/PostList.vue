<script setup>
import { ref, watch } from 'vue';
import { api } from '../api.js';

const props = defineProps({ q: { type: String, default: '' }, page: { type: Number, default: 1 } });
const data = ref(null);
const error = ref('');
const search = ref(props.q);

async function load() {
  error.value = '';
  try { data.value = await api.list(props.q, props.page); }
  catch (e) { data.value = null; error.value = e.message + (e.cause ? ` (${e.cause})` : ''); }
}
function link(page) {
  return `#/?page=${page}${props.q ? `&q=${encodeURIComponent(props.q)}` : ''}`;
}
function submit() { location.hash = `#/?q=${encodeURIComponent(search.value.trim())}`; }

watch(() => [props.q, props.page], () => { search.value = props.q; load(); }, { immediate: true });
</script>

<template>
  <form @submit.prevent="submit"><input v-model="search" type="text" placeholder="제목·내용 검색" /></form>
  <p v-if="error" class="error">{{ error }}</p>
  <template v-if="data">
    <p class="meta">전체 {{ data.total }}건</p>
    <table>
      <tr><th class="num">번호</th><th>제목</th><th>작성자</th><th>작성일</th><th class="num">조회</th></tr>
      <tr v-if="!data.items.length"><td colspan="5">게시글이 없습니다. <a href="#/write">첫 글을 작성</a>해 보세요.</td></tr>
      <tr v-for="p in data.items" :key="p.id">
        <td class="num">{{ p.id }}</td>
        <td><a :href="`#/posts/${p.id}`">{{ p.title }}</a></td>
        <td>{{ p.author }}</td>
        <td>{{ String(p.createdAt).slice(0, 16) }}</td>
        <td class="num">{{ p.views }}</td>
      </tr>
    </table>
    <p class="pager">
      <template v-for="n in data.pages" :key="n">
        <strong v-if="n === data.page">{{ n }}</strong>
        <a v-else :href="link(n)">{{ n }}</a>
      </template>
    </p>
  </template>
</template>
