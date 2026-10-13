%% SHT31 + ESP32 Real-time Dashboard + MQTT Publish (HiveMQ Public Broker)
% ต่อยอดจาก SHT31RealTimeDashboard.m
% ต้องใช้: MATLAB Support Package for Arduino Hardware
%          Industrial Communication Toolbox (ฟังก์ชัน mqttclient, R2022a ขึ้นไป)
% ดูข้อมูลได้ที่: https://www.hivemq.com/demos/websocket-client/

%% 1. กำหนดพารามิเตอร์และการเชื่อมต่อ
clear; clc; close all;

comPort    = 'COM7';                 % เปลี่ยนให้ตรงกับพอร์ตของ ESP32
boardType  = 'ESP32-WROOM-DevKitV1';
sht31_addr = '0x44';                 % I2C Address (0x44 หรือ 0x45)
cmd_measure = [hex2dec('24'), hex2dec('00')]; % High repeatability, no clock stretching

% --- ตั้งค่า MQTT ---
brokerURL   = "tcp://broker.hivemq.com";   % MATLAB ใช้ TCP พอร์ต 1883
brokerPort  = 1883;
clientID    = "matlab-esp32-" + string(randi(1e6));  % ต้องไม่ซ้ำกับคนอื่นบน broker สาธารณะ
mqttTopic   = "iot/esp32/sht31";      % << เปลี่ยนเป็นชื่อเฉพาะของคุณ (broker นี้ใครก็ subscribe ได้)
publishEvery = 2.0;                         % ส่ง MQTT ทุกกี่วินาที (ไม่ควรถี่เกินไปบน broker สาธารณะ)

fprintf('กำลังเชื่อมต่อกับ ESP32 ที่พอร์ต %s...\n', comPort);
esp   = arduino(comPort, boardType, 'Libraries', 'I2C');
sht31 = device(esp, 'I2CAddress', sht31_addr);
disp('เชื่อมต่อ ESP32 สำเร็จ!');

fprintf('กำลังเชื่อมต่อ MQTT broker %s:%d ...\n', brokerURL, brokerPort);
mqClient = [];
try
    mqClient = mqttclient(brokerURL, Port=brokerPort, ClientID=clientID, KeepAliveDuration=60);
    fprintf('เชื่อมต่อ MQTT สำเร็จ  Topic: %s\n', mqttTopic);
catch ME
    warning('เชื่อมต่อ MQTT ไม่สำเร็จ: %s\nDashboard จะทำงานต่อโดยไม่ส่ง MQTT', ME.message);
end

%% 2. ออกแบบ Dashboard UI
fig = figure('Name', 'ESP32 + SHT31 IoT Dashboard & MQTT', ...
             'NumberTitle', 'off', ...
             'Color', [0.12 0.14 0.18], ...
             'Position', [100, 100, 1100, 680]);

% การ์ดอุณหภูมิ
uicontrol('Style', 'text', 'Position', [40, 595, 230, 25], ...
          'String', 'CURRENT TEMPERATURE', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.9 0.45 0.2], 'BackgroundColor', [0.18 0.20 0.26]);
lblTempNow = uicontrol('Style', 'text', 'Position', [40, 525, 230, 70], ...
                       'String', '--.- °C', 'FontSize', 28, 'FontWeight', 'bold', ...
                       'ForegroundColor', [1 1 1], 'BackgroundColor', [0.18 0.20 0.26]);

% การ์ดความชื้น
uicontrol('Style', 'text', 'Position', [290, 595, 230, 25], ...
          'String', 'CURRENT HUMIDITY', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.2 0.7 0.9], 'BackgroundColor', [0.18 0.20 0.26]);
lblHumNow = uicontrol('Style', 'text', 'Position', [290, 525, 230, 70], ...
                      'String', '--.- %', 'FontSize', 28, 'FontWeight', 'bold', ...
                      'ForegroundColor', [1 1 1], 'BackgroundColor', [0.18 0.20 0.26]);

% การ์ดสถิติ
uicontrol('Style', 'text', 'Position', [540, 595, 300, 25], ...
          'String', 'HISTORICAL STATISTICS', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.8 0.8 0.8], 'BackgroundColor', [0.18 0.20 0.26]);
lblStats = uicontrol('Style', 'text', 'Position', [540, 525, 300, 70], ...
                     'String', sprintf('T Min: -- | Max: -- | Avg: --\nH Min: -- | Max: -- | Avg: --'), ...
                     'FontSize', 9, 'HorizontalAlignment', 'center', ...
                     'ForegroundColor', [0.85 0.85 0.85], 'BackgroundColor', [0.18 0.20 0.26]);

% สถานะ MQTT
lblMqtt = uicontrol('Style', 'text', 'Position', [40, 495, 800, 22], ...
                    'String', 'MQTT: --', 'FontSize', 9, 'HorizontalAlignment', 'left', ...
                    'ForegroundColor', [0.6 0.9 0.6], 'BackgroundColor', [0.12 0.14 0.18]);

% ปุ่มควบคุม
stopRunning = false;
uicontrol('Style', 'pushbutton', 'String', 'Stop Acquisition', ...
          'Position', [870, 575, 180, 40], 'FontWeight', 'bold', ...
          'BackgroundColor', [0.85 0.25 0.25], 'ForegroundColor', [1 1 1], ...
          'Callback', @(~, ~) assignin('caller', 'stopRunning', true));

exportRequested = false;
uicontrol('Style', 'pushbutton', 'String', 'Export History (CSV)', ...
          'Position', [870, 525, 180, 40], 'FontWeight', 'bold', ...
          'BackgroundColor', [0.25 0.55 0.35], 'ForegroundColor', [1 1 1], ...
          'Callback', @(~, ~) assignin('caller', 'exportRequested', true));

% กราฟอุณหภูมิ
axTemp = subplot('Position', [0.08, 0.30, 0.88, 0.38]);
hTempLine = animatedline(axTemp, 'Color', [1.0 0.45 0.2], 'LineWidth', 2);
title(axTemp, 'Temperature History Over Time', 'Color', [0.9 0.9 0.9], 'FontSize', 11);
ylabel(axTemp, 'Temperature (°C)', 'Color', [0.9 0.9 0.9]);
set(axTemp, 'Color', [0.16 0.18 0.23], 'XColor', [0.7 0.7 0.7], 'YColor', [0.7 0.7 0.7], 'GridColor', [0.3 0.3 0.3]);
grid(axTemp, 'on');

% กราฟความชื้น
axHum = subplot('Position', [0.08, 0.08, 0.88, 0.17]);
hHumLine = animatedline(axHum, 'Color', [0.2 0.75 1.0], 'LineWidth', 2);
title(axHum, 'Relative Humidity History Over Time', 'Color', [0.9 0.9 0.9], 'FontSize', 11);
xlabel(axHum, 'Elapsed Time (seconds)', 'Color', [0.9 0.9 0.9]);
ylabel(axHum, '%RH', 'Color', [0.9 0.9 0.9]);
set(axHum, 'Color', [0.16 0.18 0.23], 'XColor', [0.7 0.7 0.7], 'YColor', [0.7 0.7 0.7], 'GridColor', [0.3 0.3 0.3]);
grid(axHum, 'on');

%% 3. โครงสร้างข้อมูล
historyLog  = struct('Time', [], 'Temp', [], 'Hum', []);
tStart      = tic;
lastPublish = -inf;
pubCount    = 0;

%% 4. Execution Loop
while ~stopRunning && ishandle(fig)
    try
        % 4.1 อ่านค่าจาก SHT31 (แปลงเป็น double ก่อน เพื่อกัน overflow ตอน bitshift)
        write(sht31, cmd_measure);
        pause(0.02);
        raw = double(read(sht31, 6));

        % 4.2 ตรวจ CRC ของแต่ละคู่ไบต์ (ทิ้งค่าที่เสียจากสัญญาณรบกวน I2C)
        if sht31crc(raw(1:2)) ~= raw(3) || sht31crc(raw(4:5)) ~= raw(6)
            warning('CRC ไม่ถูกต้อง ข้ามรอบนี้');
            pause(0.5);
            continue;
        end

        % 4.3 แปลงค่า
        rawTemp = raw(1)*256 + raw(2);
        tempC   = -45 + 175 * rawTemp / 65535;
        rawHum  = raw(4)*256 + raw(5);
        humPct  = 100 * rawHum / 65535;
        tElapsed = toc(tStart);

        % 4.4 บันทึกประวัติ
        historyLog.Time(end+1, 1) = tElapsed;
        historyLog.Temp(end+1, 1) = tempC;
        historyLog.Hum(end+1, 1)  = humPct;

        % 4.5 อัปเดต Dashboard
        lblTempNow.String = sprintf('%.2f °C', tempC);
        lblHumNow.String  = sprintf('%.2f %%', humPct);
        lblStats.String = sprintf(...
            'T -> Min: %.1f°C | Max: %.1f°C | Avg: %.1f°C\nH -> Min: %.1f%% | Max: %.1f%% | Avg: %.1f%%', ...
            min(historyLog.Temp), max(historyLog.Temp), mean(historyLog.Temp), ...
            min(historyLog.Hum),  max(historyLog.Hum),  mean(historyLog.Hum));

        addpoints(hTempLine, tElapsed, tempC);
        addpoints(hHumLine,  tElapsed, humPct);
        axTemp.XLim = [0, max(10, tElapsed + 1)];
        axHum.XLim  = [0, max(10, tElapsed + 1)];

        % 4.6 ส่ง MQTT (JSON) ตามรอบ publishEvery
        if ~isempty(mqClient) && (tElapsed - lastPublish) >= publishEvery
            payload = jsonencode(struct( ...
                'device',      'esp32-sht31', ...
                'temperature', round(tempC, 2), ...
                'humidity',    round(humPct, 2), ...
                'timestamp',   char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'))));
            try
                write(mqClient, mqttTopic, payload, QualityOfService=0, Retain=false);
                pubCount    = pubCount + 1;
                lastPublish = tElapsed;
                lblMqtt.String = sprintf('MQTT: ส่งแล้ว %d ครั้ง  |  %s  ->  %s', pubCount, mqttTopic, payload);
            catch MEp
                lblMqtt.String = ['MQTT ERROR: ' MEp.message];
            end
        end

        % 4.7 Export CSV
        if exportRequested
            exportRequested = false;
            tTable = table(historyLog.Time, historyLog.Temp, historyLog.Hum, ...
                'VariableNames', {'ElapsedSec', 'Temp_C', 'Humidity_Pct'});
            fname = sprintf('SHT31_Log_%s.csv', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
            writetable(tTable, fname);
            fprintf('บันทึกไฟล์ประวัติข้อมูลแล้ว: %s\n', fname);
        end

        drawnow limitrate;
        pause(0.5);

    catch ME
        warning('เกิดข้อผิดพลาด: %s', ME.message);
        break;
    end
end

%% 5. คืนทรัพยากร
clear mqClient sht31 esp;
disp('ปิดการเชื่อมต่อ MQTT และ I2C เรียบร้อย');

%% ---- Local function: CRC-8 ของ SHT31 (poly 0x31, init 0xFF) ----
function crc = sht31crc(bytes)
    crc = uint8(255);
    for b = uint8(bytes(:)')
        crc = bitxor(crc, b);
        for k = 1:8
            if bitand(crc, uint8(128))
                crc = bitxor(bitshift(crc, 1), uint8(49));
            else
                crc = bitshift(crc, 1);
            end
        end
    end
    crc = double(crc);
end
