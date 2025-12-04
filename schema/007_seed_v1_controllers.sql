-- Seed v1_controllers table with all known V1 ETH Registrar Controllers
-- This ensures all historical controllers are available for indexing from any starting block
-- These were retrieved from Base Registrar ControllerAdded events

INSERT OR IGNORE INTO v1_controllers (controller_address, added_block_number, is_active, added_tx_hash) VALUES
-- Controller 1: Added at V1 launch (May 2019)
('0x4fe4e666be5752f1fdd210f4ab5de2cc26e3e0e8', 9380422, 1, '0xeec39f7b60f177691601b4c4f90ea31d7f27344824abceda3f4417772d7b715e'),
-- Controller 2: Added shortly after launch
('0x60c7c2a24b5e86c38639fd1586917a8fef66a56d', 9380466, 1, '0xbd27ed3473911a633d4df33f0666674f0d02906e812d30b4a0d08f00a0f8ba04'),
-- Controller 3: Added day 1
('0xcf60916b6cb4753f58533808fa610fcbd4098ec0', 9381046, 1, '0x5c83b117a84e88341c70df551f8be393e2989a4f6ca0395f8089cc3a1e8439a1'),
-- Controller 4: Added ~1 week after launch
('0x6109dd117aa5486605fc85e040ab00163a75c662', 9411159, 1, '0x83e31c88aef44ba2ce964cec50141d7322d5c3e97c46ddf5dcc52cfdc53f9b0d'),
-- Controller 5: Added ~2 weeks after launch (May 2019)
('0x283af0b28c62c092c9727f1ee09c02ca627eb7f5', 9456489, 1, '0x4e1532fbb95ec440a816d3ff5e49280796a03117b703adbea82de0897850861f'),
-- Controller 6: Added ~2022-2023
('0xd4416b13d2b3a9abae7acd5d6c2bbdbe25686401', 16996231, 1, '0x47fc32e0e2882dac1691464e3aa93126f6963ca8ae651c30b7721555c3aedc6d'),
-- Controller 7: Added ~2025 (most recent)
('0x59e16fccd424cc24e280be16e11bcd56fb0ce547', 23044126, 1, '0xa4da70aac93eeee2be6c74d3c496451a07195e46127be573dd218886caef505a');
