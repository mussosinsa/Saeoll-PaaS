<script setup>
// Hash routes (no vue-router): #/  #/posts/:id  #/write  #/posts/:id/edit
import { onMounted, onUnmounted, ref } from 'vue';
import PostList from './components/PostList.vue';
import PostView from './components/PostView.vue';
import PostForm from './components/PostForm.vue';
import { api } from './api.js';

const route = ref({ name: 'list' });
const dbStatus = ref(null);

function parse() {
  const h = location.hash.replace(/^#/, '') || '/';
  let m;
  if ((m = h.match(/^\/posts\/(\d+)\/edit$/))) return { name: 'edit', id: Number(m[1]) };
  if ((m = h.match(/^\/posts\/(\d+)$/))) return { name: 'view', id: Number(m[1]) };
  if (h === '/write') return { name: 'write' };
  const params = new URLSearchParams(h.split('?')[1] || '');
  return { name: 'list', q: params.get('q') || '', page: Number(params.get('page')) || 1 };
}
function onHash() { route.value = parse(); window.scrollTo(0, 0); }

async function checkDb() {
  try { dbStatus.value = await api.dbcheck(); } catch (e) { dbStatus.value = { status: 'error', error: e.message }; }
}

onMounted(() => { onHash(); window.addEventListener('hashchange', onHash); checkDb(); });
onUnmounted(() => window.removeEventListener('hashchange', onHash));
</script>

<template>
  <header>
    <h1><a href="#/">Vue 게시판</a></h1>
    <a class="btn" href="#/write">글쓰기</a>
  </header>

  <PostList v-if="route.name === 'list'" :q="route.q" :page="route.page" />
  <PostView v-else-if="route.name === 'view'" :id="route.id" />
  <PostForm v-else-if="route.name === 'write'" />
  <PostForm v-else-if="route.name === 'edit'" :id="route.id" />

  <footer>
    Vue 3 · API
    <span v-if="dbStatus?.status === 'ok'">정상 (DB {{ dbStatus.db_host }}, MariaDB {{ dbStatus.server_version }})</span>
    <span v-else-if="dbStatus" class="error">오류: {{ dbStatus.error }}</span>
    <span v-else>확인 중…</span>
  </footer>
</template>

<style>
body { font-family: system-ui, "Malgun Gothic", sans-serif; max-width: 860px; margin: 0 auto; padding: 16px; color: #222; }
header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #333; margin-bottom: 16px; }
header a { color: #222; text-decoration: none; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 8px; border-bottom: 1px solid #ddd; text-align: left; }
.num { text-align: right; width: 70px; }
a { color: #0b5ed7; }
input[type=text], input[type=password], textarea { width: 100%; box-sizing: border-box; padding: 8px; margin: 4px 0 12px; }
textarea { min-height: 220px; }
.btn { display: inline-block; padding: 6px 14px; border: 1px solid #0b5ed7; border-radius: 4px; background: #0b5ed7;
       color: #fff !important; text-decoration: none; cursor: pointer; font-size: 14px; }
.btn.gray { background: #fff; color: #0b5ed7 !important; }
.btn.red { background: #dc3545; border-color: #dc3545; }
.error { color: #dc3545; }
.meta { color: #666; font-size: .9em; }
.content { white-space: pre-wrap; padding: 16px 0; border-bottom: 1px solid #ddd; }
.pager a, .pager strong { margin: 0 4px; }
footer { margin-top: 32px; color: #888; font-size: .8em; }
</style>
