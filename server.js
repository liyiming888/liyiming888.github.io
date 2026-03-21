const express = require('express');
const cors = require('cors');
const nodemailer = require('nodemailer');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const fs = require('fs');
const path = require('path');
const axios = require('axios');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));

// 数据文件路径
const USERS_FILE = path.join(__dirname, 'users.json');
const CONVERSATIONS_FILE = path.join(__dirname, 'conversations.json');

// 初始化存储
const initDataFile = (file, defaultData) => {
    if (!fs.existsSync(file)) {
        fs.writeFileSync(file, JSON.stringify(defaultData, null, 2));
    }
};
initDataFile(USERS_FILE, []);
initDataFile(CONVERSATIONS_FILE, {});

const readUsers = () => JSON.parse(fs.readFileSync(USERS_FILE));
const writeUsers = (data) => fs.writeFileSync(USERS_FILE, JSON.stringify(data, null, 2));
const readConversations = () => JSON.parse(fs.readFileSync(CONVERSATIONS_FILE));
const writeConversations = (data) => fs.writeFileSync(CONVERSATIONS_FILE, JSON.stringify(data, null, 2));

// 邮件配置
const transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: parseInt(process.env.SMTP_PORT),
    secure: true,
    auth: {
        user: process.env.SMTP_USER,
        pass: process.env.SMTP_PASS
    }
});

// 存储验证码
const verificationCodes = new Map();

const sendVerificationEmail = async (email, code) => {
    const mailOptions = {
        from: `"松果AI" <${process.env.SMTP_USER}>`,
        to: email,
        subject: '松果AI 验证码',
        html: `
            <div style="font-family: 'Segoe UI', Arial, sans-serif; max-width: 500px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 20px; background: linear-gradient(145deg, #f9fafc, #ffffff);">
                <div style="text-align: center;">
                    <span style="font-size: 48px;">🌰✨</span>
                    <h2 style="color: #FFB347;">松果AI</h2>
                </div>
                <p style="color: #333; font-size: 16px;">您好，</p>
                <p style="color: #333; font-size: 16px;">您正在使用松果AI的验证服务，您的验证码是：</p>
                <div style="text-align: center; margin: 30px 0;">
                    <span style="font-size: 32px; font-weight: bold; background: #FFD966; padding: 12px 24px; border-radius: 50px; letter-spacing: 4px;">${code}</span>
                </div>
                <p style="color: #666; font-size: 14px;">验证码有效期为10分钟，请勿泄露给他人。</p>
                <p style="color: #999; font-size: 12px; margin-top: 30px;">此邮件由系统自动发送，请勿回复。</p>
            </div>
        `
    };
    await transporter.sendMail(mailOptions);
};

const generateCode = () => Math.floor(100000 + Math.random() * 900000).toString();

// JWT认证中间件
const authenticateToken = (req, res, next) => {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];
    if (!token) return res.status(401).json({ error: '未提供认证令牌' });
    jwt.verify(token, process.env.JWT_SECRET, (err, user) => {
        if (err) return res.status(403).json({ error: '令牌无效或已过期' });
        req.user = user;
        next();
    });
};

// -------------------- API 路由 --------------------

// 1. 发送验证码
app.post('/api/send-code', async (req, res) => {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: '邮箱不能为空' });
    const code = generateCode();
    verificationCodes.set(email, { code, expire: Date.now() + 10 * 60 * 1000 });
    try {
        await sendVerificationEmail(email, code);
        res.json({ message: '验证码已发送' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: '邮件发送失败，请检查邮箱地址或稍后重试' });
    }
});

// 2. 验证码登录/自动注册
app.post('/api/login-with-code', async (req, res) => {
    const { email, code } = req.body;
    const record = verificationCodes.get(email);
    if (!record || record.code !== code || record.expire < Date.now()) {
        return res.status(400).json({ error: '验证码无效或已过期' });
    }
    let users = readUsers();
    let user = users.find(u => u.email === email);
    if (!user) {
        const hashedPwd = await bcrypt.hash('temporary', 10);
        user = { id: Date.now().toString(), email, password: hashedPwd, model: 'deepseek-chat', memoryEnabled: false, avatar: `https://api.dicebear.com/7.x/avataaars/svg?seed=${email}` };
        users.push(user);
        writeUsers(users);
    }
    const token = jwt.sign({ id: user.id, email: user.email }, process.env.JWT_SECRET, { expiresIn: '7d' });
    verificationCodes.delete(email);
    res.json({ token, user: { email: user.email, model: user.model, memoryEnabled: user.memoryEnabled, avatar: user.avatar } });
});

// 3. 密码登录
app.post('/api/login-with-password', async (req, res) => {
    const { email, password } = req.body;
    const users = readUsers();
    const user = users.find(u => u.email === email);
    if (!user) return res.status(401).json({ error: '邮箱未注册' });
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) return res.status(401).json({ error: '密码错误' });
    const token = jwt.sign({ id: user.id, email: user.email }, process.env.JWT_SECRET, { expiresIn: '7d' });
    res.json({ token, user: { email: user.email, model: user.model, memoryEnabled: user.memoryEnabled, avatar: user.avatar } });
});

// 4. 注册（密码+验证码）
app.post('/api/register', async (req, res) => {
    const { email, password, code } = req.body;
    const record = verificationCodes.get(email);
    if (!record || record.code !== code || record.expire < Date.now()) {
        return res.status(400).json({ error: '验证码无效或已过期' });
    }
    let users = readUsers();
    if (users.find(u => u.email === email)) {
        return res.status(400).json({ error: '邮箱已注册' });
    }
    const hashedPwd = await bcrypt.hash(password, 10);
    const newUser = {
        id: Date.now().toString(),
        email,
        password: hashedPwd,
        model: 'deepseek-chat',
        memoryEnabled: false,
        avatar: `https://api.dicebear.com/7.x/avataaars/svg?seed=${email}`
    };
    users.push(newUser);
    writeUsers(users);
    verificationCodes.delete(email);
    res.json({ message: '注册成功' });
});

// 5. 忘记密码（重置密码）
app.post('/api/reset-password', async (req, res) => {
    const { email, newPassword, code } = req.body;
    const record = verificationCodes.get(email);
    if (!record || record.code !== code || record.expire < Date.now()) {
        return res.status(400).json({ error: '验证码无效或已过期' });
    }
    let users = readUsers();
    const userIndex = users.findIndex(u => u.email === email);
    if (userIndex === -1) return res.status(404).json({ error: '用户不存在' });
    users[userIndex].password = await bcrypt.hash(newPassword, 10);
    writeUsers(users);
    verificationCodes.delete(email);
    res.json({ message: '密码重置成功' });
});

// 6. 获取用户信息
app.get('/api/user', authenticateToken, (req, res) => {
    const users = readUsers();
    const user = users.find(u => u.id === req.user.id);
    if (!user) return res.status(404).json({ error: '用户不存在' });
    res.json({ email: user.email, model: user.model, memoryEnabled: user.memoryEnabled, avatar: user.avatar });
});

// 7. 更新用户设置
app.put('/api/user/settings', authenticateToken, (req, res) => {
    const { model, memoryEnabled } = req.body;
    let users = readUsers();
    const userIndex = users.findIndex(u => u.id === req.user.id);
    if (userIndex === -1) return res.status(404).json({ error: '用户不存在' });
    if (model !== undefined) users[userIndex].model = model;
    if (memoryEnabled !== undefined) users[userIndex].memoryEnabled = memoryEnabled;
    writeUsers(users);
    res.json({ message: '设置更新成功', settings: { model: users[userIndex].model, memoryEnabled: users[userIndex].memoryEnabled } });
});

// 8. 滑块验证轨迹分析
app.post('/api/verify-slider', (req, res) => {
    const { duration, points } = req.body;
    if (!points || points.length < 5) {
        return res.json({ success: false, reason: '轨迹点不足' });
    }

    let totalDistance = 0;
    let timeDeltas = [];
    let speedVariations = [];
    let previous = points[0];
    for (let i = 1; i < points.length; i++) {
        const p = points[i];
        const deltaX = p.x - previous.x;
        const deltaT = p.time - previous.time;
        if (deltaT <= 0) continue;
        const speed = deltaX / deltaT;
        totalDistance += Math.abs(deltaX);
        timeDeltas.push(deltaT);
        speedVariations.push(speed);
        previous = p;
    }

    // 总时长 0.3~5秒
    if (duration < 300 || duration > 5000) {
        return res.json({ success: false, reason: '滑动时间异常' });
    }
    // 总位移约 300px（滑块宽度，可接受范围）
    const expectedDistance = 300;
    if (totalDistance < expectedDistance * 0.7 || totalDistance > expectedDistance * 1.3) {
        return res.json({ success: false, reason: '滑动距离不足' });
    }
    // 速度方差检测（过于匀速则拒绝）
    if (speedVariations.length >= 2) {
        const avgSpeed = speedVariations.reduce((a,b) => a+b, 0) / speedVariations.length;
        let variance = 0;
        for (let v of speedVariations) variance += Math.pow(v - avgSpeed, 2);
        variance /= speedVariations.length;
        if (variance < 0.5) {
            return res.json({ success: false, reason: '滑动过于匀速，疑似机器人' });
        }
    }
    // 可选：检测是否有反向移动（真人常有微小回退）
    let hasReverse = false;
    for (let i = 1; i < points.length; i++) {
        if (points[i].x < points[i-1].x - 5) {
            hasReverse = true;
            break;
        }
    }
    if (!hasReverse) {
        // 允许没有回退，但可降低信任分，这里不直接拒绝
    }

    res.json({ success: true });
});

// 9. 天气代理接口（缓存1小时）
let cachedWeather = null;
let lastWeatherUpdate = 0;

async function getWeather() {
    const now = Date.now();
    if (cachedWeather && (now - lastWeatherUpdate) < 55 * 60 * 1000) {
        return cachedWeather;
    }
    try {
        const url = `https://api.seniverse.com/v3/weather/now.json?key=${process.env.WEATHER_PUBLIC_KEY}&location=beijing&language=zh-Hans&unit=c`;
        const response = await axios.get(url);
        const data = response.data.results[0];
        cachedWeather = {
            success: true,
            temperature: data.now.temperature,
            text: data.now.text,
            last_update: new Date().toISOString()
        };
        lastWeatherUpdate = now;
        return cachedWeather;
    } catch (err) {
        console.error('天气API错误', err);
        return { success: false, error: '天气服务暂时不可用' };
    }
}

app.get('/api/weather', async (req, res) => {
    const weather = await getWeather();
    res.json(weather);
});

// 10. 聊天接口（带记忆、天气上下文）
app.post('/api/chat', authenticateToken, async (req, res) => {
    const { message, imageText } = req.body;
    const userId = req.user.id;
    let users = readUsers();
    const user = users.find(u => u.id === userId);
    if (!user) return res.status(404).json({ error: '用户不存在' });

    let userContent = message;
    if (imageText && imageText.trim()) {
        userContent = `[图片内容]\n${imageText}\n\n[用户问题]\n${message}`;
    }

    let conversations = readConversations();
    if (!conversations[userId]) conversations[userId] = [];
    let history = user.memoryEnabled ? conversations[userId] : [];

    // 获取天气并注入系统消息
    const weather = await getWeather();
    let systemContent = '你是松果AI，一个温暖、聪明、富有洞察力的助手。你会记住对话历史（如果用户开启了记忆），并根据上下文提供贴心的回答。你可以分析用户性格，但需保持自然。';
    if (weather.success) {
        systemContent += `\n当前天气：${weather.text}，温度 ${weather.temperature}°C。如果用户询问天气或出门建议，请结合这个信息给出建议。`;
    }

    const messages = [
        { role: 'system', content: systemContent },
        ...history,
        { role: 'user', content: userContent }
    ];

    try {
        const response = await fetch('https://api.deepseek.com/v1/chat/completions', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${process.env.DEEPSEEK_API_KEY}`
            },
            body: JSON.stringify({
                model: user.model || 'deepseek-chat',
                messages: messages,
                temperature: 0.7,
                max_tokens: 2000
            })
        });
        const data = await response.json();
        const reply = data.choices[0].message.content;

        if (user.memoryEnabled) {
            conversations[userId].push({ role: 'user', content: userContent });
            conversations[userId].push({ role: 'assistant', content: reply });
            if (conversations[userId].length > 40) conversations[userId] = conversations[userId].slice(-40);
            writeConversations(conversations);
        }

        res.json({ reply });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'AI服务繁忙，请稍后再试' });
    }
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
    console.log(`松果AI后端服务已启动，端口：${PORT}`);
});
