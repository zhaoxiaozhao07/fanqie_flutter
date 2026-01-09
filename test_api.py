#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
临时脚本：测试番茄小说API目录接口
"""

import json
import sys
import io
import ssl
import socket
import time

# 修复Windows控制台编码问题
if sys.platform == 'win32':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

def read_chunked_response(sock, timeout=60):
    """手动读取chunked编码的响应"""
    sock.settimeout(timeout)
    data = b""
    
    while True:
        try:
            # 读取chunk大小行
            size_line = b""
            while not size_line.endswith(b"\r\n"):
                byte = sock.recv(1)
                if not byte:
                    break
                size_line += byte
            
            if not size_line:
                break
                
            # 解析chunk大小
            size_str = size_line.strip().decode('ascii')
            if not size_str:
                break
            chunk_size = int(size_str, 16)
            
            if chunk_size == 0:
                # 最后一个chunk
                sock.recv(2)  # 读取结尾的\r\n
                break
            
            # 读取chunk数据
            chunk_data = b""
            remaining = chunk_size
            while remaining > 0:
                received = sock.recv(min(remaining, 8192))
                if not received:
                    break
                chunk_data += received
                remaining -= len(received)
            
            data += chunk_data
            
            # 读取chunk结尾的\r\n
            sock.recv(2)
            
        except socket.timeout:
            print(f"[WARN] 读取超时，已读取 {len(data)} 字节")
            break
        except Exception as e:
            print(f"[WARN] 读取错误: {e}，已读取 {len(data)} 字节")
            break
    
    return data

def test_directory_api():
    """测试获取书籍目录的API"""
    
    host = "qkfqapi.vv9v.cn"
    path = "/api/directory?book_id=7276384138653862966"
    
    print("=" * 60)
    print("测试 API: 获取书籍目录")
    print("=" * 60)
    print(f"请求URL: https://{host}{path}")
    print(f"请求方法: GET")
    print("-" * 60)
    
    max_retries = 3
    for attempt in range(max_retries):
        print(f"\n尝试 {attempt + 1}/{max_retries}...")
        
        try:
            # 创建SSL上下文
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            # 创建socket连接
            sock = socket.create_connection((host, 443), timeout=60)
            ssl_sock = ssl_context.wrap_socket(sock, server_hostname=host)
            
            # 构建HTTP请求
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                f"Accept: application/json\r\n"
                f"Accept-Language: zh-CN,zh;q=0.9\r\n"
                f"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36\r\n"
                f"Connection: close\r\n"
                f"\r\n"
            )
            
            # 发送请求
            ssl_sock.sendall(request.encode('utf-8'))
            
            # 读取响应头
            response_data = b""
            while b"\r\n\r\n" not in response_data:
                chunk = ssl_sock.recv(1024)
                if not chunk:
                    break
                response_data += chunk
            
            # 分离头部和body
            header_end = response_data.find(b"\r\n\r\n")
            headers_raw = response_data[:header_end].decode('utf-8')
            body_start = response_data[header_end + 4:]
            
            # 解析响应头
            header_lines = headers_raw.split("\r\n")
            status_line = header_lines[0]
            print(f"状态行: {status_line}")
            
            headers = {}
            for line in header_lines[1:]:
                if ": " in line:
                    key, value = line.split(": ", 1)
                    headers[key.lower()] = value
            
            print("响应头:")
            for key, value in headers.items():
                print(f"  {key}: {value}")
            print("-" * 60)
            
            # 检查是否是chunked编码
            is_chunked = headers.get('transfer-encoding', '').lower() == 'chunked'
            
            if is_chunked:
                print("检测到chunked编码，手动解析...")
                # 将已读取的body部分放回
                # 创建一个新的socket-like对象来处理剩余数据
                
                # 简单方法：直接读取所有剩余数据
                all_data = body_start
                ssl_sock.settimeout(30)
                
                while True:
                    try:
                        chunk = ssl_sock.recv(65536)
                        if not chunk:
                            break
                        all_data += chunk
                    except socket.timeout:
                        print(f"[INFO] 读取完成或超时，共读取 {len(all_data)} 字节")
                        break
                    except Exception as e:
                        print(f"[WARN] 读取错误: {e}")
                        break
                
                # 尝试解析chunked数据
                # 简化处理：直接查找JSON内容
                content = all_data.decode('utf-8', errors='replace')
                
                # 查找JSON开始位置
                json_start = content.find('{"')
                if json_start >= 0:
                    content = content[json_start:]
                    # 查找最后一个完整的}
                    # 移除chunked编码的大小标记
                    import re
                    # 移除类似 "\r\n1fff\r\n" 这样的chunk标记
                    content = re.sub(r'\r\n[0-9a-fA-F]+\r\n', '', content)
                    content = content.replace('\r\n0\r\n', '')
            else:
                # 非chunked，直接读取
                content_length = int(headers.get('content-length', 0))
                all_data = body_start
                while len(all_data) < content_length:
                    chunk = ssl_sock.recv(8192)
                    if not chunk:
                        break
                    all_data += chunk
                content = all_data.decode('utf-8')
            
            ssl_sock.close()
            
            print(f"\n[OK] 成功读取数据，内容长度: {len(content)} 字符")
            
            # 尝试解析JSON
            try:
                data = json.loads(content)
                print("[OK] JSON解析成功")
                process_response_data(data)
                return  # 成功，退出重试循环
                
            except json.JSONDecodeError as e:
                print(f"[WARN] JSON解析失败: {e}")
                # 尝试修复
                fixed_content = try_fix_json(content)
                if fixed_content:
                    try:
                        data = json.loads(fixed_content)
                        print("[OK] 修复后JSON解析成功")
                        process_response_data(data)
                        return
                    except:
                        pass
                
                if attempt < max_retries - 1:
                    print("将重试...")
                    time.sleep(2)
                else:
                    print("\n原始内容前1000字符:")
                    print(content[:1000])
                    
        except Exception as e:
            print(f"[FAIL] 错误: {type(e).__name__}: {e}")
            if attempt < max_retries - 1:
                print("将重试...")
                time.sleep(2)
    
    print("=" * 60)

def try_fix_json(content):
    """尝试修复不完整的JSON"""
    # 找到最后一个完整的}
    last_brace = content.rfind('}')
    if last_brace > 0:
        test_content = content[:last_brace+1]
        # 补全可能缺失的括号
        open_brackets = test_content.count('[') - test_content.count(']')
        open_braces = test_content.count('{') - test_content.count('}')
        test_content += ']' * max(0, open_brackets) + '}' * max(0, open_braces)
        return test_content
    return None

def process_response_data(data):
    """处理响应数据"""
    print(f"\n响应数据类型: {type(data).__name__}")
    if isinstance(data, dict):
        print(f"顶层键: {list(data.keys())}")
        
        if "code" in data:
            print(f"\n响应代码: {data.get('code')}")
            print(f"响应消息: {data.get('message', data.get('msg', '成功'))}")
        
        if "data" in data:
            chapters_data = data.get("data")
            print(f"\ndata字段类型: {type(chapters_data).__name__}")
            
            if isinstance(chapters_data, list):
                chapters = chapters_data
            elif isinstance(chapters_data, dict):
                print(f"data字典键: {list(chapters_data.keys())}")
                # 查找章节列表
                chapters = None
                for key in ['lists', 'chapters', 'chapter_list', 'list', 'items', 'directory']:
                    if key in chapters_data:
                        chapters = chapters_data[key]
                        print(f"在 data.{key} 中找到章节数据")
                        break
            else:
                chapters = None
            
            if chapters and isinstance(chapters, list):
                print(f"\n[OK] 共获取到 {len(chapters)} 个章节")
                
                if len(chapters) > 0:
                    # 显示第一个章节的结构
                    if isinstance(chapters[0], dict):
                        print(f"章节数据字段: {list(chapters[0].keys())}")
                    
                    print("\n" + "=" * 40)
                    print("前10个章节:")
                    print("=" * 40)
                    for i, chapter in enumerate(chapters[:10]):
                        if isinstance(chapter, dict):
                            title = chapter.get("title", chapter.get("name", chapter.get("chapter_title", "未知标题")))
                            chapter_id = chapter.get("item_id", chapter.get("id", chapter.get("chapter_id", "未知ID")))
                            print(f"  {i+1}. [{chapter_id}] {title}")
                        else:
                            print(f"  {i+1}. {chapter}")
                    
                    if len(chapters) > 10:
                        print("\n" + "=" * 40)
                        print("最后10个章节:")
                        print("=" * 40)
                        for i, chapter in enumerate(chapters[-10:]):
                            if isinstance(chapter, dict):
                                title = chapter.get("title", chapter.get("name", chapter.get("chapter_title", "未知标题")))
                                chapter_id = chapter.get("item_id", chapter.get("id", chapter.get("chapter_id", "未知ID")))
                                print(f"  {len(chapters)-9+i}. [{chapter_id}] {title}")
            else:
                print("[WARN] 未找到章节列表数据")



if __name__ == "__main__":
    test_directory_api()