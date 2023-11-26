import requests
from bs4 import BeautifulSoup

# 发送请求获取网页内容
url = 'https://tiloid.com/'
response = requests.get(url)
soup = BeautifulSoup(response.content, 'html.parser')

# 获取所有博客文章的标题和作者
articles = soup.find_all('div', class_='post')
latest_articles = articles[:5]  # 获取最新的5篇文章

# 生成 README.md 文件内容
readme_content = '# Today I Learned for programmers - Tiloid\n\n'
readme_content += '## Latest Articles\n\n'
for article in latest_articles:
    title = article.find('a', class_='post-title').text.strip()
    author = article.find('span', class_='post-author').text.strip()
    readme_content += f'- **{title}** by {author}\n\n'

# 更新 README.md 文件
with open('README.md', 'w') as file:
    file.write(readme_content)

print('README.md 文件已更新')
