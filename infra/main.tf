terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "kubernetes" {
  name     = "kubernetes"
  location = "West Europe"
}

resource "azurerm_network_security_group" "kubernetes" {
  name                = "kubernetes-security-group"
  location            = azurerm_resource_group.kubernetes.location
  resource_group_name = azurerm_resource_group.kubernetes.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-k8s-api"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }


  security_rule {
    name                       = "allow-internal-communication"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/24"
    destination_address_prefix = "10.0.0.0/24"
  }
}

resource "azurerm_virtual_network" "kubernetes" {
  name                = "kubernetes-network"
  location            = azurerm_resource_group.kubernetes.location
  resource_group_name = azurerm_resource_group.kubernetes.name
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "control_plane" {
  name                 = "control-plane-subnet"
  resource_group_name  = azurerm_resource_group.kubernetes.name
  virtual_network_name = azurerm_virtual_network.kubernetes.name
  address_prefixes     = ["10.0.0.0/27"]
}

resource "azurerm_subnet_network_security_group_association" "control_plane_nsg_association" {
  subnet_id                 = azurerm_subnet.control_plane.id
  network_security_group_id = azurerm_network_security_group.kubernetes.id
}

resource "azurerm_subnet" "worker_nodes" {
  name                 = "worker-nodes-subnet"
  resource_group_name  = azurerm_resource_group.kubernetes.name
  virtual_network_name = azurerm_virtual_network.kubernetes.name
  address_prefixes     = ["10.0.0.32/27"]
}

resource "azurerm_subnet_network_security_group_association" "worker_nodes_nsg_association" {
  subnet_id                 = azurerm_subnet.worker_nodes.id
  network_security_group_id = azurerm_network_security_group.kubernetes.id
}

resource "azurerm_public_ip" "kubernetes" {
  for_each            = var.vm_names
  name                = "${each.key}-public-ip"
  resource_group_name = azurerm_resource_group.kubernetes.name
  location            = azurerm_resource_group.kubernetes.location
  allocation_method   = "Static"
}

variable "vm_names" {
  type = map(string)
  default = {
    "control-plane-1" = "control-plane"
    "worker-node-1"   = "worker-node"
    "worker-node-2"   = "worker-node"
  }
}

resource "azurerm_network_interface" "kubernetes_nic" {
  for_each            = var.vm_names
  name                = "${each.key}-nic"
  location            = azurerm_resource_group.kubernetes.location
  resource_group_name = azurerm_resource_group.kubernetes.name

  ip_configuration {
    name                          = each.key
    subnet_id                     = each.value == "control-plane" ? azurerm_subnet.control_plane.id : azurerm_subnet.worker_nodes.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.kubernetes[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "kubernetes_nodes" {
  for_each            = var.vm_names
  name                = each.key
  resource_group_name = azurerm_resource_group.kubernetes.name
  location            = azurerm_resource_group.kubernetes.location
  size                = each.value == "control-plane" ? "Standard_F2" : "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.kubernetes_nic[each.key].id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa_azure_vm.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }
}