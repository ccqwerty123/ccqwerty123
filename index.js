'use strict';

var fs = require('fs-extra');
var Parser = require('rss-parser');

const rssParser = new Parser();
async function start() {
    const blogResp = await rssParser.parseURL('https://blog.cmyr.ltd/atom.xml');
    if (Date.now() - new Date(blogResp.lastBuildDate).getTime() > 48 * 60 * 60 * 1000) {
        console.log('最近48小时内没有博客更新，跳过本次更新');
        return;
    }
    const items = [...blogResp.items.slice(0, 5)];
    const text = items.map((e) => `- [${e.title}](${e.link})`).join('\n');
    const readme = await fs.readFile('README.md', 'utf-8');
    const newReadme = readme.replace(/<!-- BLOG_START -->([\s\S]*?)<!-- BLOG_END -->/, `<!-- BLOG_START -->\n${text}\n<!-- BLOG_END -->`);
    await fs.writeFile('README.md', newReadme);
    console.log('更新博客链接成功');
}
start();
