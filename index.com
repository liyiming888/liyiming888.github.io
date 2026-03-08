<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Continuous Point Cloud Morph | 连续丝滑点云变形</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            /* 全局消除点击蓝色框、选中高亮 */
            outline: none;
            -webkit-tap-highlight-color: transparent;
            user-select: none;
            -webkit-user-select: none;
        }
        body {
            width: 100vw;
            height: 100vh;
            overflow: hidden;
            background: #000;
            cursor: pointer;
        }
        /* 消除canvas焦点轮廓 */
        canvas {
            outline: none;
            display: block;
        }
        #info {
            position: fixed;
            top: 24px;
            left: 50%;
            transform: translateX(-50%);
            color: #ffffff;
            font-family: system-ui, -apple-system, sans-serif;
            font-size: 22px;
            font-weight: 500;
            z-index: 10;
        }
        /* 底部颜色选择栏 */
        .color-picker-container {
            position: fixed;
            bottom: 24px;
            left: 50%;
            transform: translateX(-50%);
            display: flex;
            gap: 12px;
            padding: 12px 16px;
            border-radius: 12px;
            background: rgba(0, 0, 0, 0.7);
            backdrop-filter: blur(10px);
            overflow-x: auto;
            max-width: 90vw;
            z-index: 10;
        }
        /* 颜色选择按钮 */
        .color-btn {
            width: 36px;
            height: 36px;
            border-radius: 8px;
            border: 2px solid transparent;
            cursor: pointer;
            transition: all 0.2s ease;
            flex-shrink: 0;
        }
        .color-btn:hover {
            transform: scale(1.1);
        }
        .color-btn:active {
            transform: scale(0.95);
        }
        .color-btn.active {
            border-color: #ffffff;
            box-shadow: 0 0 10px rgba(255, 255, 255, 0.5);
        }
    </style>
</head>
<body>
    <div id="info">Shape: Sphere (Click to morph)</div>
    <div class="color-picker-container" id="colorPicker"></div>

    <script type="module">
        // 引入Three.js 3D引擎CDN，零本地依赖
        import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js';

        // ===================== 可自由调整的参数 =====================
        const POINT_COUNT = 50000; // 点的数量，默认5万，性能足够可改10万+
        const POINT_SIZE = 0.012;    // 单个点的大小，调小后点云更分散不密集
        const ANIMATION_DURATION = 60; // 变形动画时长，数值越小速度越快
        // ============================================================

        // 1. 3D场景基础初始化
        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
        const renderer = new THREE.WebGLRenderer({ antialias: true });
        renderer.setSize(window.innerWidth, window.innerHeight);
        renderer.setPixelRatio(window.devicePixelRatio);
        document.body.appendChild(renderer.domElement);

        // 2. 黄金螺旋算法生成均匀球面点云（保证所有形状点索引一一对应，变形无错乱）
        function generateBaseSphereData(count) {
            const positions = new Float32Array(count * 3);
            const goldenAngle = Math.PI * (3 - Math.sqrt(5)); // 黄金角，保证均匀分布

            for (let i = 0; i < count; i++) {
                const y = 1 - (i / (count - 1)) * 2;
                const radius = Math.sqrt(1 - y * y);
                const theta = goldenAngle * i;

                const x = Math.cos(theta) * radius;
                const z = Math.sin(theta) * radius;

                positions[i * 3] = x;
                positions[i * 3 + 1] = y;
                positions[i * 3 + 2] = z;
            }
            return positions;
        }

        // 3. 颜色渐变预设（保留原有默认颜色，新增多组好看的渐变）
        const colorPresets = [
            {
                name: "默认彩虹渐变",
                btnColor: "linear-gradient(135deg, #ff6b6b, #4ecdc4, #45b7d1)",
                generateColor: (x, y, z) => {
                    return [(x + 1) / 2, (y + 1) / 2, (z + 1) / 2];
                }
            },
            {
                name: "粉紫梦幻渐变",
                btnColor: "linear-gradient(135deg, #f093fb, #f5576c)",
                generateColor: (x, y, z) => {
                    return [0.8 + x * 0.2, 0.3 + y * 0.3, 0.9 + z * 0.1];
                }
            },
            {
                name: "蓝青冷调渐变",
                btnColor: "linear-gradient(135deg, #4facfe, #00f2fe)",
                generateColor: (x, y, z) => {
                    return [0.1 + x * 0.2, 0.7 + y * 0.3, 0.95 + z * 0.05];
                }
            },
            {
                name: "橙红暖调渐变",
                btnColor: "linear-gradient(135deg, #fa709a, #fee140)",
                generateColor: (x, y, z) => {
                    return [0.95 + x * 0.05, 0.4 + y * 0.5, 0.1 + z * 0.1];
                }
            },
            {
                name: "黑白极简渐变",
                btnColor: "linear-gradient(135deg, #ffffff, #000000)",
                generateColor: (x, y, z) => {
                    const gray = (x + y + z) / 3 + 0.5;
                    return [gray, gray, gray];
                }
            },
            {
                name: "绿黄清新渐变",
                btnColor: "linear-gradient(135deg, #38ef7d, #11998e)",
                generateColor: (x, y, z) => {
                    return [0.5 + x * 0.3, 0.9 + y * 0.1, 0.2 + z * 0.2];
                }
            },
            {
                name: "玫红鎏金渐变",
                btnColor: "linear-gradient(135deg, #ff0844, #ffb199)",
                generateColor: (x, y, z) => {
                    return [0.9 + x * 0.1, 0.6 + y * 0.3, 0.2 + z * 0.1];
                }
            }
        ];

        // 4. 不同形状的点云映射函数（微调尺寸，适配分散后的点云，保证不超出屏幕）
        // 球体
        function mapToSphere(basePositions, count, scale) {
            const positions = new Float32Array(count * 3);
            for (let i = 0; i < count * 3; i++) {
                positions[i] = basePositions[i] * scale;
            }
            return positions;
        }

        // 立方体
        function mapToCube(basePositions, count, size) {
            const positions = new Float32Array(count * 3);
            for (let i = 0; i < count; i++) {
                const x = basePositions[i * 3];
                const y = basePositions[i * 3 + 1];
                const z = basePositions[i * 3 + 2];
                const maxAbs = Math.max(Math.abs(x), Math.abs(y), Math.abs(z));
                const scale = size / maxAbs;
                positions[i * 3] = x * scale;
                positions[i * 3 + 1] = y * scale;
                positions[i * 3 + 2] = z * scale;
            }
            return positions;
        }

        // 圆环
        function mapToTorus(basePositions, count, majorRadius, minorRadius) {
            const positions = new Float32Array(count * 3);
            for (let i = 0; i < count; i++) {
                const x = basePositions[i * 3];
                const y = basePositions[i * 3 + 1];
                const z = basePositions[i * 3 + 2];
                const theta = Math.atan2(y, x);
                const phi = Math.atan2(z, Math.sqrt(x * x + y * y));
                positions[i * 3] = (majorRadius + minorRadius * Math.cos(phi)) * Math.cos(theta);
                positions[i * 3 + 1] = (majorRadius + minorRadius * Math.cos(phi)) * Math.sin(theta);
                positions[i * 3 + 2] = minorRadius * Math.sin(phi);
            }
            return positions;
        }

        // 八面体
        function mapToOctahedron(basePositions, count, size) {
            const positions = new Float32Array(count * 3);
            for (let i = 0; i < count; i++) {
                const x = basePositions[i * 3];
                const y = basePositions[i * 3 + 1];
                const z = basePositions[i * 3 + 2];
                const l1Norm = Math.abs(x) + Math.abs(y) + Math.abs(z);
                const scale = size / l1Norm;
                positions[i * 3] = x * scale;
                positions[i * 3 + 1] = y * scale;
                positions[i * 3 + 2] = z * scale;
            }
            return positions;
        }

        // 5. 预生成所有形状的顶点数据（微调尺寸，保证点云分散后仍完整在屏幕内）
        const basePositions = generateBaseSphereData(POINT_COUNT);
        const shapes = [
            { name: 'Sphere', positions: mapToSphere(basePositions, POINT_COUNT, 1.7) },
            { name: 'Cube', positions: mapToCube(basePositions, POINT_COUNT, 1.7) },
            { name: 'Torus', positions: mapToTorus(basePositions, POINT_COUNT, 1.4, 0.5) },
            { name: 'Octahedron', positions: mapToOctahedron(basePositions, POINT_COUNT, 1.8) }
        ];

        // 6. 核心变形状态管理
        let currentShapeIndex = 0;
        let morphProgress = 0;
        let isAnimating = false;
        let currentColorPreset = 0; // 当前选中的颜色预设

        // 变形核心数组
        const currentPositions = new Float32Array(POINT_COUNT * 3);
        const startPositions = new Float32Array(POINT_COUNT * 3);
        const targetPositions = new Float32Array(POINT_COUNT * 3);
        const currentColors = new Float32Array(POINT_COUNT * 3); // 点云颜色数组

        // 初始化形状位置
        currentPositions.set(shapes[0].positions);
        startPositions.set(shapes[0].positions);
        targetPositions.set(shapes[0].positions);

        // 7. 创建点云几何体与材质
        const geometry = new THREE.BufferGeometry();
        geometry.setAttribute('position', new THREE.BufferAttribute(currentPositions, 3).setUsage(THREE.DynamicDrawUsage));
        geometry.setAttribute('color', new THREE.BufferAttribute(currentColors, 3).setUsage(THREE.DynamicDrawUsage));

        const material = new THREE.PointsMaterial({
            size: POINT_SIZE,
            vertexColors: true,
            transparent: true,
            opacity: 0.85,
            sizeAttenuation: true,
            depthWrite: false
        });

        // 8. 创建点云物体并添加到场景
        const pointCloud = new THREE.Points(geometry, material);
        scene.add(pointCloud);
        camera.position.z = 6;

        // 9. 工具函数
        // 缓动函数，保证丝滑变形
        function easeInOutSine(t) {
            return -(Math.cos(Math.PI * t) - 1) / 2;
        }

        // 更新顶部形状提示文本
        function updateInfoText() {
            document.getElementById('info').textContent = `Shape: ${shapes[currentShapeIndex].name} (Click to morph)`;
        }

        // 更新点云颜色（核心颜色切换函数）
        function updatePointColors() {
            const preset = colorPresets[currentColorPreset];
            for (let i = 0; i < POINT_COUNT; i++) {
                const x = basePositions[i * 3];
                const y = basePositions[i * 3 + 1];
                const z = basePositions[i * 3 + 2];
                const [r, g, b] = preset.generateColor(x, y, z);
                currentColors[i * 3] = r;
                currentColors[i * 3 + 1] = g;
                currentColors[i * 3 + 2] = b;
            }
            geometry.attributes.color.needsUpdate = true;
        }

        // 生成底部颜色选择按钮
        function initColorPicker() {
            const container = document.getElementById('colorPicker');
            colorPresets.forEach((preset, index) => {
                const btn = document.createElement('div');
                btn.className = 'color-btn';
                btn.style.background = preset.btnColor;
                btn.title = preset.name;
                if (index === currentColorPreset) btn.classList.add('active');

                // 点击切换颜色
                btn.addEventListener('click', (e) => {
                    e.stopPropagation(); // 阻止触发形状变形
                    if (currentColorPreset === index) return;

                    // 更新选中状态
                    document.querySelectorAll('.color-btn').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    currentColorPreset = index;

                    // 更新点云颜色
                    updatePointColors();
                });

                container.appendChild(btn);
            });
        }

        // 10. 核心点击变形事件
        window.addEventListener('click', () => {
            if (isAnimating) return;

            // 设置变形起始和目标位置
            startPositions.set(currentPositions);
            currentShapeIndex = (currentShapeIndex + 1) % shapes.length;
            targetPositions.set(shapes[currentShapeIndex].positions);

            // 重置动画状态
            morphProgress = 0;
            isAnimating = true;
            updateInfoText();
        });

        // 11. 窗口大小自适应
        window.addEventListener('resize', () => {
            camera.aspect = window.innerWidth / window.innerHeight;
            camera.updateProjectionMatrix();
            renderer.setSize(window.innerWidth, window.innerHeight);
        });

        // 12. 动画循环
        function animate() {
            requestAnimationFrame(animate);

            // 点云自动旋转
            pointCloud.rotation.x += 0.005;
            pointCloud.rotation.y += 0.01;

            // 逐点变形逻辑
            if (isAnimating) {
                morphProgress += 1 / ANIMATION_DURATION;
                if (morphProgress >= 1) {
                    morphProgress = 1;
                    isAnimating = false;
                }

                const easedProgress = easeInOutSine(morphProgress);
                for (let i = 0; i < POINT_COUNT * 3; i++) {
                    currentPositions[i] = startPositions[i] + (targetPositions[i] - startPositions[i]) * easedProgress;
                }
                geometry.attributes.position.needsUpdate = true;
            }

            renderer.render(scene, camera);
        }

        // 初始化：生成颜色、创建颜色选择器、启动动画
        updatePointColors();
        initColorPicker();
        animate();
    </script>
</body>
</html>
