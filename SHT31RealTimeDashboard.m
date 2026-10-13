%% 1. กำหนดพารามิเตอร์และการเชื่อมต่อ
clear; clc; close all;

comPort = 'COM7';              % เปลี่ยนให้ตรงกับพอร์ตของ ESP32
boardType = 'ESP32-WROOM-DevKitV1';
sht31_addr = '0x44';           % I2C Address (0x44 หรือ 0x45)
cmd_measure = [hex2dec('24'), hex2dec('00')]; % High repeatability

fprintf('กำลังเชื่อมต่อกับ ESP32 ที่พอร์ต %s...\n', comPort);
esp = arduino(comPort, boardType, 'Libraries', 'I2C');
sht31 = device(esp, 'I2CAddress', sht31_addr);
disp('เชื่อมต่อสำเร็จ! กำลังเปิด Dashboard...');

%% 2. ออกแบบ Dashboard UI
fig = figure('Name', 'ESP32 + SHT31 IoT Dashboard & History', ...
             'NumberTitle', 'off', ...
             'Color', [0.12 0.14 0.18], ... % ธีม Modern Dark
             'Position', [100, 100, 1100, 680]);

% --- โซน Dashboard การ์ดแสดงผลค่าปัจจุบัน (ด้านบน) ---
% การ์ดอุณหภูมิปัจจุบัน
uicontrol('Style', 'text', 'Position', [40, 595, 230, 25], ...
          'String', 'CURRENT TEMPERATURE', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.9 0.45 0.2], 'BackgroundColor', [0.18 0.20 0.26]);
lblTempNow = uicontrol('Style', 'text', 'Position', [40, 525, 230, 70], ...
                       'String', '--.- °C', 'FontSize', 28, 'FontWeight', 'bold', ...
                       'ForegroundColor', [1 1 1], 'BackgroundColor', [0.18 0.20 0.26]);

% การ์ดความชื้นปัจจุบัน
uicontrol('Style', 'text', 'Position', [290, 595, 230, 25], ...
          'String', 'CURRENT HUMIDITY', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.2 0.7 0.9], 'BackgroundColor', [0.18 0.20 0.26]);
lblHumNow = uicontrol('Style', 'text', 'Position', [290, 525, 230, 70], ...
                      'String', '--.- %', 'FontSize', 28, 'FontWeight', 'bold', ...
                      'ForegroundColor', [1 1 1], 'BackgroundColor', [0.18 0.20 0.26]);

% การ์ดสถิติรวม (Min / Max / Avg)
uicontrol('Style', 'text', 'Position', [540, 595, 300, 25], ...
          'String', 'HISTORICAL STATISTICS', 'FontSize', 10, 'FontWeight', 'bold', ...
          'ForegroundColor', [0.8 0.8 0.8], 'BackgroundColor', [0.18 0.20 0.26]);
lblStats = uicontrol('Style', 'text', 'Position', [540, 525, 300, 70], ...
                     'String', sprintf('T Min: -- | Max: -- | Avg: --\nH Min: -- | Max: -- | Avg: --'), ...
                     'FontSize', 9, 'HorizontalAlignment', 'center', ...
                     'ForegroundColor', [0.85 0.85 0.85], 'BackgroundColor', [0.18 0.20 0.26]);

% ปุ่มควบคุม (Stop & Export CSV)
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

% --- โซน History Graphs (ด้านล่าง) ---
% กราฟประวัติอุณหภูมิ
axTemp = subplot('Position', [0.08, 0.30, 0.88, 0.38]);
hTempLine = animatedline(axTemp, 'Color', [1.0 0.45 0.2], 'LineWidth', 2);
title(axTemp, 'Temperature History Over Time', 'Color', [0.9 0.9 0.9], 'FontSize', 11);
ylabel(axTemp, 'Temperature (°C)', 'Color', [0.9 0.9 0.9]);
set(axTemp, 'Color', [0.16 0.18 0.23], 'XColor', [0.7 0.7 0.7], 'YColor', [0.7 0.7 0.7], 'GridColor', [0.3 0.3 0.3]);
grid(axTemp, 'on');

% กราฟประวัติความชื้น
axHum = subplot('Position', [0.08, 0.08, 0.88, 0.17]);
hHumLine = animatedline(axHum, 'Color', [0.2 0.75 1.0], 'LineWidth', 2);
title(axHum, 'Relative Humidity History Over Time', 'Color', [0.9 0.9 0.9], 'FontSize', 11);
xlabel(axHum, 'Elapsed Time (seconds)', 'Color', [0.9 0.9 0.9]);
ylabel(axHum, '%RH', 'Color', [0.9 0.9 0.9]);
set(axHum, 'Color', [0.16 0.18 0.23], 'XColor', [0.7 0.7 0.7], 'YColor', [0.7 0.7 0.7], 'GridColor', [0.3 0.3 0.3]);
grid(axHum, 'on');

%% 3. โครงสร้างจัดเก็บ History Data
historyLog = struct('Time', [], 'Temp', [], 'Hum', []);
tStart = tic;

%% 4. Execution Loop
while ~stopRunning && ishandle(fig)
    try
        % 4.1 สั่งอ่านค่า I2C จาก SHT31
        write(sht31, cmd_measure);
        pause(0.02);
        raw = read(sht31, 6);
        
        % 4.2 แปลงค่าอุณหภูมิและความชื้น (แก้ไข Delimiter เรียบร้อย)
        rawTemp = bitshift(raw(1), 8) + raw(2);
        tempC = -45 + (175 * (double(rawTemp) / 65535));
        
        rawHum = bitshift(raw(4), 8) + raw(5);
        humPct = 100 * (double(rawHum) / 65535);
        
        tElapsed = toc(tStart);
        
        % 4.3 บันทึกประวัติลง Array
        historyLog.Time(end+1, 1) = tElapsed;
        historyLog.Temp(end+1, 1) = tempC;
        historyLog.Hum(end+1, 1)  = humPct;
        
        % 4.4 อัปเดต Dashboard Cards
        lblTempNow.String = sprintf('%.2f °C', tempC);
        lblHumNow.String  = sprintf('%.2f %%', humPct);
        
        % อัปเดตสถิติสรุปภาพรวม (Min / Max / Mean)
        lblStats.String = sprintf(...
            'T -> Min: %.1f°C | Max: %.1f°C | Avg: %.1f°C\nH -> Min: %.1f%% | Max: %.1f%% | Avg: %.1f%%', ...
            min(historyLog.Temp), max(historyLog.Temp), mean(historyLog.Temp), ...
            min(historyLog.Hum), max(historyLog.Hum), mean(historyLog.Hum));
        
        % 4.5 อัปเดตกราฟ History
        addpoints(hTempLine, tElapsed, tempC);
        addpoints(hHumLine, tElapsed, humPct);
        
        % ขยายสเกลแกนเวลาตามข้อมูลทั้งหมด
        axTemp.XLim = [0, max(10, tElapsed + 1)];
        axHum.XLim  = [0, max(10, tElapsed + 1)];
        
        % ตรวจสอบการกด Export CSV
        if exportRequested
            exportRequested = false;
            tTable = table(historyLog.Time, historyLog.Temp, historyLog.Hum, ...
                'VariableNames', {'ElapsedSec', 'Temp_C', 'Humidity_Pct'});
            fname = sprintf('SHT31_Log_%s.csv', datestr(now, 'yyyymmdd_HHMMSS'));
            writetable(tTable, fname);
            fprintf('บันทึกไฟล์ประวัติข้อมูลแล้ว: %s\n', fname);
        end
        
        drawnow limitrate;
        pause(0.5); % รอบการอ่านทุก 0.5 วินาที
        
    catch ME
        warning('เกิดข้อผิดพลาด: %s', ME.message);
        break;
    end
end

%% 5. คืนทรัพยากร
clear sht31 esp;
disp('ปิดการเชื่อมต่อ I2C เรียบร้อย');